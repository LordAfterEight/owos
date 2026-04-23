const std = @import("std");
const owos = @import("root.zig");
const rendering = owos.fb.rendering;
const C = rendering.Color;

const ramfs = owos.ramfs;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const max_input = 256;
const max_tokens = 32;

// Static buffers for OwOFS import/export to avoid blowing the 16 KB kernel stack.
var fs_io_buf: [4096]u8 = undefined;
var fs_path_buf: [256]u8 = undefined;

pub const Shell = struct {
    log: *rendering.ScrollingLog,
    buf: [max_input]u8 = undefined,
    len: usize = 0,
    tokens: [max_tokens][]const u8 = undefined,
    token_count: usize = 0,

    // Lockdown state
    locked: bool = false,
    lock_tag: [ChaCha20Poly1305.tag_length]u8 = undefined,
    lock_attempts: u8 = 0,
    prev_verbosity: owos.klog.LoggingVerbosity = .verbose,
    prev_serial: bool = false,

    pub fn init() Shell {
        var self = Shell{ .log = &rendering.ScrollingLog.instance };
        owos.klog.info("SHELL: started", .{});
        rendering.swap();
        self.prompt();
        rendering.swap();
        return self;
    }

    fn prompt(self: *Shell) void {
        self.log.print("OwOS <- ", .{}, C.Grey);
    }

    fn tokenize(self: *Shell) void {
        const input = self.buf[0..self.len];
        self.token_count = 0;
        var i: usize = 0;
        while (i < input.len and self.token_count < max_tokens) {
            while (i < input.len and input[i] == ' ') i += 1;
            if (i >= input.len) break;
            if (input[i] == '"') {
                // Quoted token: skip opening quote, find closing quote
                i += 1;
                const start = i;
                while (i < input.len and input[i] != '"') i += 1;
                self.tokens[self.token_count] = input[start..i];
                self.token_count += 1;
                if (i < input.len) i += 1; // skip closing quote
            } else {
                const start = i;
                while (i < input.len and input[i] != ' ') i += 1;
                self.tokens[self.token_count] = input[start..i];
                self.token_count += 1;
            }
        }
    }

    const ResolveResult = struct {
        file: *ramfs.File,
        index: usize,
    };

    /// Resolve a file argument. Accepts either `#N` (index) or a name.
    /// If a name matches multiple files, prints an error and returns null.
    fn resolve_file(self: *Shell, arg: []const u8) ?ResolveResult {
        // Try #N index syntax
        if (arg.len > 1 and arg[0] == '#') {
            const index = std.fmt.parseInt(usize, arg[1..], 10) catch {
                self.log.print("Invalid index: ", .{}, .BrightRed);
                self.log.println("{s}", .{arg}, .White);
                return null;
            };
            const file = ramfs.get_file_by_index(index) orelse {
                self.log.print("No file at index: ", .{}, .BrightRed);
                self.log.println("{d}", .{index}, .White);
                return null;
            };
            return .{ .file = file, .index = index };
        }

        // Name lookup — check for duplicates
        const count = ramfs.count_by_name(arg);
        if (count == 0) {
            self.log.print("File not found: ", .{}, .BrightRed);
            self.log.println("{s}", .{arg}, .White);
            return null;
        }
        if (count > 1) {
            self.log.print("Ambiguous name: ", .{}, .BrightRed);
            self.log.print("{s}", .{arg}, .White);
            self.log.println(" ({d} files). Use #N index from 'list'", .{count}, .BrightYellow);
            return null;
        }

        // Unique match — find it and its index
        const file_list = ramfs.get_files();
        for (file_list, 0..) |*slot, i| {
            if (slot.*) |*f| {
                if (std.mem.eql(u8, f.name(), arg)) {
                    return .{ .file = f, .index = i };
                }
            }
        }
        return null;
    }

    /// Compute a MAC tag over `data` using a fixed key/nonce.
    /// Used to verify passphrase+code without storing them in plaintext.
    fn compute_lock_tag(data: []const u8) [ChaCha20Poly1305.tag_length]u8 {
        // Use a fixed all-zero key and nonce — this is just a MAC for verification,
        // not encryption. The "ciphertext" is discarded.
        const mac_key = [_]u8{0x4C} ** ChaCha20Poly1305.key_length; // 'L' for lockdown
        const mac_nonce = [_]u8{0} ** ChaCha20Poly1305.nonce_length;
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        // We need a throwaway ciphertext buffer. Use a stack buffer up to max_input.
        var discard: [max_input * 2]u8 = undefined;
        const len = @min(data.len, discard.len);
        ChaCha20Poly1305.encrypt(discard[0..len], &tag, data[0..len], &.{}, mac_nonce, mac_key);
        @memset(discard[0..len], 0);
        return tag;
    }

    fn format_hex_u4(val: u4) u8 {
        const v: u8 = val;
        return if (v < 10) '0' + v else 'A' - 10 + v;
    }

    fn cmd_lockdown(self: *Shell) void {
        if (self.locked) {
            self.log.println("System is already locked.", .{}, .BrightYellow);
            return;
        }
        if (self.token_count < 2) {
            self.log.println("Usage: lockdown <passphrase>", .{}, .BrightYellow);
            return;
        }
        const passphrase = self.rest_after_token(0) orelse {
            self.log.println("Usage: lockdown <passphrase>", .{}, .BrightYellow);
            return;
        };

        // Generate a random 4-byte one-time code, displayed as XXXX-XXXX
        var code_bytes: [4]u8 = undefined;
        owos.rdrand.fill(&code_bytes);
        var code_str: [9]u8 = undefined; // "XXXX-XXXX"
        for (0..4) |i| {
            const idx = if (i < 2) i * 2 else i * 2 + 1;
            code_str[idx] = format_hex_u4(@truncate(code_bytes[i] >> 4));
            code_str[idx + 1] = format_hex_u4(@truncate(code_bytes[i] & 0x0F));
        }
        code_str[4] = '-';

        // Build passphrase + code concatenation for hashing
        var hash_buf: [max_input + 9]u8 = undefined;
        @memcpy(hash_buf[0..passphrase.len], passphrase);
        @memcpy(hash_buf[passphrase.len .. passphrase.len + 9], &code_str);
        const hash_data = hash_buf[0 .. passphrase.len + 9];

        self.lock_tag = compute_lock_tag(hash_data);
        @memset(hash_buf[0..hash_data.len], 0);

        // Save state and lock down
        self.prev_verbosity = owos.klog.verbosity;
        self.prev_serial = owos.serial.enabled;
        owos.klog.verbosity = .quiet;
        owos.serial.enabled = false;
        self.locked = true;
        self.lock_attempts = 0;
        rendering.lockdown_overlay = true;

        self.log.clear();

        self.log.println("System locked down.", .{}, .BrightYellow);
        self.log.print("One-time unlock code: ", .{}, .Grey);
        self.log.println("{s}", .{&code_str}, .BrightGreen);
        self.log.println("This code will NOT be shown again.", .{}, .PureRed);
        self.log.println("Use: unlock <passphrase> <code>", .{}, .Grey);
        self.log.println("WARNING: 2 failed attempts means full data wipe", .{}, .PureRed);

        // Wipe code from stack
        @memset(&code_bytes, 0);
        @memset(&code_str, 0);
    }

    fn cmd_unlock(self: *Shell) void {
        if (!self.locked) {
            self.log.println("System is not locked.", .{}, .BrightYellow);
            return;
        }
        if (self.token_count < 3) {
            self.log.println("Usage: unlock <passphrase> <code>", .{}, .BrightYellow);
            return;
        }

        // Reconstruct: everything after "unlock " is passphrase + code
        // The code is the last token (XXXX-XXXX format), passphrase is everything between
        const code_tok = self.tokens[self.token_count - 1];
        const passphrase_end = @intFromPtr(code_tok.ptr) - 1 - @intFromPtr(&self.buf);
        const input = self.buf[0..self.len];
        // Find start of passphrase (after "unlock ")
        var pass_start: usize = 0;
        {
            const cmd_tok = self.tokens[0];
            pass_start = @intFromPtr(cmd_tok.ptr) + cmd_tok.len - @intFromPtr(&self.buf);
            while (pass_start < input.len and input[pass_start] == ' ') pass_start += 1;
        }
        if (pass_start >= passphrase_end) {
            self.log.println("Usage: unlock <passphrase> <code>", .{}, .BrightYellow);
            return;
        }
        const passphrase = input[pass_start..passphrase_end];

        // Build passphrase + code for verification
        var hash_buf: [max_input + 9]u8 = undefined;
        @memcpy(hash_buf[0..passphrase.len], passphrase);
        @memcpy(hash_buf[passphrase.len .. passphrase.len + code_tok.len], code_tok);
        const hash_data = hash_buf[0 .. passphrase.len + code_tok.len];

        const tag = compute_lock_tag(hash_data);
        @memset(hash_buf[0..hash_data.len], 0);

        // Constant-time compare
        var diff: u8 = 0;
        for (0..ChaCha20Poly1305.tag_length) |i| {
            diff |= tag[i] ^ self.lock_tag[i];
        }

        if (diff == 0) {
            // Success — unlock
            self.locked = false;
            self.lock_attempts = 0;
            @memset(&self.lock_tag, 0);
            rendering.lockdown_overlay = false;
            owos.klog.verbosity = self.prev_verbosity;
            owos.serial.enabled = self.prev_serial;
            self.log.println("System unlocked.", .{}, .BrightGreen);
        } else {
            self.lock_attempts += 1;
            const remaining = 2 - self.lock_attempts;
            if (remaining == 0) {
                // WIPE EVERYTHING
                self.log.println("Authentication failed. Maximum attempts reached.", .{}, .PureRed);
                self.log.println("Wiping all data...", .{}, .PureRed);

                // Wipe master key and all files
                @memset(&ramfs.master_key, 0);
                for (ramfs.get_files()) |*slot| {
                    if (slot.*) |*f| f.delete();
                }
                // Clear lockdown state
                self.locked = false;
                self.lock_attempts = 0;
                @memset(&self.lock_tag, 0);
                rendering.lockdown_overlay = false;
                owos.klog.verbosity = .quiet;
                owos.serial.enabled = false;

                // Clear screen — present clean state
                self.log.clear();
                self.log.println("All data wiped. System reset.", .{}, .Grey);
            } else {
                self.log.print("Invalid passphrase or code. ", .{}, .BrightRed);
                self.log.println("{d} attempt(s) remaining.", .{remaining}, .BrightYellow);
            }
        }
    }

    fn execute(self: *Shell) void {
        self.tokenize();
        defer self.len = 0;

        if (self.token_count == 0) return;

        const cmd = self.tokens[0];

        // Always allow unlock when locked
        if (std.mem.eql(u8, cmd, "unlock")) {
            self.cmd_unlock();
            return;
        }

        // Block sensitive commands in lockdown
        if (self.locked) {
            if (std.mem.eql(u8, cmd, "masterkey")) {
                self.log.println("Command disabled in lockdown mode.", .{}, .PureRed);
                return;
            }
            if (std.mem.eql(u8, cmd, "dump") and self.has_flag("--keys")) {
                self.log.println("Cannot reveal keys in lockdown mode.", .{}, .PureRed);
                return;
            }
            if (std.mem.eql(u8, cmd, "memdump")) {
                self.log.println("Command disabled in lockdown mode.", .{}, .PureRed);
                return;
            }
            if (std.mem.eql(u8, cmd, "serial") and self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "on")) {
                self.log.println("Cannot enable serial in lockdown mode.", .{}, .PureRed);
                return;
            }
        }

        if (std.mem.eql(u8, cmd, "help")) {
            self.log.println("Available commands:", .{}, .BrightYellow);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("befo <filename>                           Start Basic Editor For OwOS", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("new <arg>                                 Create a new object of type <arg>", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("write <ref> <content>                     Append text to a file", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("read <ref>                                Print file contents as text", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("dump <ref> [--keys]                       Hex dump (--keys to include keys)", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("delete <ref>                              Delete a file", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("list                                      List all files", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("memdump <region|addr> [n]                 Dump raw memory", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("masterkey                                 Display the master encryption key", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("clear                                     Clear the screen", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("lockdown <passphrase>                     Lock system", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("unlock <pass> <code>                      Unlock (2 failures = wipe)", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("serial on|off                             Toggle serial output", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("verbosity [quiet|normal|verbose]          Set logging verbosity", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("layout [qwerty|qwertz]                    Set keyboard layout", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("ping <ip>                                 Send ICMP echo request", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("wping <host|ip> [port]                    HTTP web ping (DNS + TCP)", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("fs scan|mount|format|info|list|read|...   OwOFS disk commands", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("shutdown                                  Power off the machine", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("reboot                                    Restart the machine", .{}, .BrightBlue);
            self.log.newline();
            self.log.println("  Commands in magenta are restricted in lockdown mode.", .{}, .BrightMagenta);
            self.log.println("  <ref> = file name or #N index from 'list'", .{}, .Grey);
        } else if (std.mem.eql(u8, cmd, "list")) {
            self.cmd_list();
        } else if (std.mem.eql(u8, cmd, "masterkey")) {
            self.cmd_masterkey();
        } else if (std.mem.eql(u8, cmd, "clear")) {
            self.log.clear();
        } else if (std.mem.eql(u8, cmd, "serial")) {
            if (self.token_count < 2) {
                self.log.print("Serial output is ", .{}, .Grey);
                if (owos.serial.enabled) {
                    self.log.println("ON", .{}, .BrightGreen);
                } else {
                    self.log.println("OFF", .{}, .BrightRed);
                }
            } else if (std.mem.eql(u8, self.tokens[1], "on")) {
                owos.serial.enabled = true;
                self.log.println("Serial output enabled", .{}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "off")) {
                owos.serial.enabled = false;
                self.log.println("Serial output disabled", .{}, .BrightRed);
            } else {
                self.log.println("Usage: serial on|off", .{}, .BrightYellow);
            }
        } else if (std.mem.eql(u8, cmd, "verbosity")) {
            if (self.token_count < 2) {
                const name: []const u8 = switch (owos.klog.verbosity) {
                    .quiet => "quiet",
                    .normal => "normal",
                    .verbose => "verbose",
                };
                self.log.print("Logging verbosity is ", .{}, .Grey);
                self.log.println("{s}", .{name}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "quiet")) {
                owos.klog.verbosity = .quiet;
                self.log.println("Verbosity set to quiet", .{}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "normal")) {
                owos.klog.verbosity = .normal;
                self.log.println("Verbosity set to normal", .{}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "verbose")) {
                owos.klog.verbosity = .verbose;
                self.log.println("Verbosity set to verbose", .{}, .BrightGreen);
            } else {
                self.log.println("Usage: verbosity quiet|normal|verbose", .{}, .BrightYellow);
            }
        } else if (std.mem.eql(u8, cmd, "layout")) {
            if (self.token_count < 2) {
                self.log.print("Keyboard layout is ", .{}, .Grey);
                self.log.println("{s}", .{owos.ps2.layout.name()}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "qwerty")) {
                owos.ps2.layout = .qwerty;
                self.log.println("Layout set to QWERTY", .{}, .BrightGreen);
            } else if (std.mem.eql(u8, self.tokens[1], "qwertz")) {
                owos.ps2.layout = .qwertz;
                self.log.println("Layout set to QWERTZ", .{}, .BrightGreen);
            } else {
                self.log.println("Usage: layout qwerty|qwertz", .{}, .BrightYellow);
            }
        } else if (std.mem.eql(u8, cmd, "shutdown")) {
            self.log.println("Shutting down...", .{}, .BrightYellow);
            rendering.swap();
            owos.acpi.shutdown();
            while (true) asm volatile ("hlt");
        } else if (std.mem.eql(u8, cmd, "reboot")) {
            self.log.println("Rebooting...", .{}, .BrightYellow);
            rendering.swap();
            owos.acpi.reboot();
            while (true) asm volatile ("hlt");
        } else if (std.mem.eql(u8, cmd, "write")) {
            self.cmd_write();
        } else if (std.mem.eql(u8, cmd, "read")) {
            self.cmd_read();
        } else if (std.mem.eql(u8, cmd, "dump")) {
            self.cmd_dump();
        } else if (std.mem.eql(u8, cmd, "memdump")) {
            self.cmd_memdump();
        } else if (std.mem.eql(u8, cmd, "delete")) {
            self.cmd_delete();
        } else if (std.mem.eql(u8, cmd, "lockdown")) {
            self.cmd_lockdown();
        } else if (std.mem.eql(u8, cmd, "befo")) {
            self.cmd_befo();
        } else if (std.mem.eql(u8, cmd, "ping")) {
            self.cmd_ping();
        } else if (std.mem.eql(u8, cmd, "wping")) {
            self.cmd_wping();
        } else if (std.mem.eql(u8, cmd, "fs")) {
            self.cmd_fs();
        } else if (std.mem.eql(u8, cmd, "new")) {
            if (self.token_count < 2) {
                self.log.println("Usage: new <type>. See 'new --help'", .{}, .BrightYellow);
            } else if (std.mem.eql(u8, self.tokens[1], "file")) {
                if (self.token_count < 3) {
                    self.log.println("Usage: new file <name>", .{}, .BrightYellow);
                } else {
                    const fname = self.tokens[2];
                    _ = ramfs.create_file(fname) catch |e| {
                        self.log.print("Error creating file: ", .{}, .BrightRed);
                        self.log.println("{s}", .{@errorName(e)}, .White);
                        return;
                    };
                    self.log.print("Created file: ", .{}, .BrightGreen);
                    self.log.println("{s}", .{fname}, .White);
                }
            } else {
                self.log.print("Invalid argument: ", .{}, .BrightRed);
                self.log.println("{s}", .{self.tokens[1]}, .White);
                self.log.println("To get a list of available arguments, type 'new --help'", .{}, .BrightYellow);
            }
        } else {
            self.log.print("Unknown command: ", .{}, C.BrightRed);
            self.log.println("{s}", .{self.buf[0..self.len]}, C.White);
        }
    }

    fn rest_after_token(self: *Shell, n: usize) ?[]const u8 {
        if (self.token_count <= n) return null;
        const input = self.buf[0..self.len];
        const last_tok = self.tokens[n];
        const tok_end = @intFromPtr(last_tok.ptr) + last_tok.len - @intFromPtr(&self.buf);
        var i = tok_end;
        while (i < input.len and input[i] == ' ') i += 1;
        if (i >= input.len) return null;
        return input[i..];
    }

    fn cmd_write(self: *Shell) void {
        if (self.token_count < 3) {
            self.log.println("Usage: write <ref> <content>", .{}, .BrightYellow);
            return;
        }
        const content = self.rest_after_token(1) orelse {
            self.log.println("Usage: write <ref> <content>", .{}, .BrightYellow);
            return;
        };
        const r = self.resolve_file(self.tokens[1]) orelse return;
        _ = r.file.write(content) catch |e| {
            self.log.print("Write error: ", .{}, .BrightRed);
            self.log.println("{s}", .{@errorName(e)}, .White);
            return;
        };
        self.log.print("Wrote {d} bytes to ", .{content.len}, .BrightGreen);
        self.log.println("{s} [#{d}]", .{ r.file.name(), r.index }, .White);
    }

    fn cmd_read(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: read <ref>", .{}, .BrightYellow);
            return;
        }
        const r = self.resolve_file(self.tokens[1]) orelse return;
        var read_buf: [4096]u8 = undefined;
        const data = r.file.read_all(&read_buf) catch |e| {
            self.log.print("Read error: ", .{}, .BrightRed);
            self.log.println("{s}", .{@errorName(e)}, .White);
            return;
        };
        if (data.len == 0) {
            self.log.println("(empty file)", .{}, .Grey);
        } else {
            self.log.println("{s}", .{data}, .White);
        }
    }

    fn cmd_delete(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: delete <ref>", .{}, .BrightYellow);
            return;
        }
        const r = self.resolve_file(self.tokens[1]) orelse return;
        const name = r.file.name();
        self.log.print("Deleted file: ", .{}, .BrightGreen);
        self.log.println("{s} [#{d}]", .{ name, r.index }, .White);
        ramfs.delete_file(r.index);
    }

    fn cmd_list(self: *Shell) void {
        const file_list = ramfs.get_files();
        var live: usize = 0;
        for (file_list) |slot| {
            if (slot != null) live += 1;
        }
        if (live == 0) {
            self.log.println("No files.", .{}, .Grey);
            return;
        }
        self.log.println("{d} file(s):", .{live}, .Grey);
        for (file_list, 0..) |slot, i| {
            const file = slot orelse continue;
            const tag_len = 16;
            const total = file.nonce.len + file.key.len + file.size + tag_len;
            self.log.print("  [#{d}] ", .{i}, .Grey);
            self.log.print("{s}", .{file.name()}, .White);
            self.log.print("  size={d}B", .{file.size}, .BrightBlue);
            self.log.print("  enc={d}B", .{file.size + tag_len}, .BrightMagenta);
            self.log.print("  total={d}B", .{total}, .BrightGreen);
            self.log.print("  writes={d}", .{file.write_count}, .BrightYellow);
            self.log.println("  addr=0x{X:0>16}", .{@intFromPtr(file.enc_data.ptr)}, .Grey);
        }
    }

    fn hex_dump(self: *Shell, label: []const u8, data: []const u8, color: C, base: usize) void {
        self.log.println("{s} ({d} bytes):", .{ label, data.len }, .Grey);
        var offset: usize = 0;
        while (offset < data.len) {
            self.log.print("0x{X:0>4}: ", .{base + offset}, .Grey);
            const end = @min(offset + 16, data.len);
            for (data[offset..end]) |b| {
                self.log.print("{X:0>2} ", .{b}, color);
            }
            var pad = end - offset;
            while (pad < 16) : (pad += 1) {
                self.log.print("   ", .{}, .Grey);
            }
            self.log.print(" |", .{}, .Grey);
            for (data[offset..end]) |b| {
                if (b >= 0x20 and b < 0x7F) {
                    self.log.print("{c}", .{b}, .White);
                } else {
                    self.log.print(".", .{}, .Grey);
                }
            }
            self.log.println("|", .{}, .Grey);
            offset = end;
        }
    }

    fn has_flag(self: *Shell, flag: []const u8) bool {
        for (self.tokens[0..self.token_count]) |tok| {
            if (std.mem.eql(u8, tok, flag)) return true;
        }
        return false;
    }

    const Region = struct {
        name: []const u8,
        addr: u64,
        desc: []const u8,
    };

    fn known_regions() [4]Region {
        return .{
            .{ .name = "ramfs", .addr = ramfs.RAMFS_BASE, .desc = "RAMFS data region" },
            .{ .name = "gdt", .addr = owos.gdt.gdt_base, .desc = "Global Descriptor Table" },
            .{ .name = "idt", .addr = owos.idt.idt_base, .desc = "Interrupt Descriptor Table" },
            .{ .name = "fb", .addr = @intFromPtr(rendering.GFB.address), .desc = "Framebuffer (front)" },
        };
    }

    fn resolve_addr(self: *Shell, s: []const u8) ?u64 {
        // Try "region+offset" syntax
        var name = s;
        var offset: u64 = 0;
        if (std.mem.indexOfScalar(u8, s, '+')) |plus| {
            name = s[0..plus];
            offset = parse_hex_u64(s[plus + 1 ..]) orelse {
                self.log.print("Invalid offset: ", .{}, .BrightRed);
                self.log.println("{s}", .{s[plus + 1 ..]}, .White);
                return null;
            };
        }

        // Check named regions
        for (known_regions()) |r| {
            if (std.mem.eql(u8, name, r.name)) return r.addr +% offset;
        }

        // Fall back to raw hex address
        return parse_hex_u64(s);
    }

    fn cmd_memdump(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: memdump <region|addr> [length]", .{}, .BrightYellow);
            self.log.println("  Use 'memdump regions' to list named regions.", .{}, .Grey);
            self.log.println("  Supports region+offset, e.g. 'memdump ramfs+100'", .{}, .Grey);
            return;
        }

        if (std.mem.eql(u8, self.tokens[1], "regions")) {
            self.log.println("Known memory regions:", .{}, .BrightYellow);
            for (known_regions()) |r| {
                self.log.print("  - ", .{}, .Grey);
                self.log.print("{s}", .{r.name}, .BrightBlue);
                self.log.print("  0x{X:0>16}  ", .{r.addr}, .Grey);
                self.log.println("{s}", .{r.desc}, .White);
            }
            return;
        }

        const addr = self.resolve_addr(self.tokens[1]) orelse {
            self.log.print("Unknown region or invalid address: ", .{}, .BrightRed);
            self.log.println("{s}", .{self.tokens[1]}, .White);
            self.log.println("Use 'memdump regions' to list named regions.", .{}, .Grey);
            return;
        };

        const length: usize = if (self.token_count >= 3)
            std.fmt.parseInt(usize, self.tokens[2], 0) catch {
                self.log.print("Invalid length: ", .{}, .BrightRed);
                self.log.println("{s}", .{self.tokens[2]}, .White);
                return;
            }
        else
            256;

        if (length == 0) {
            self.log.println("Length must be > 0", .{}, .BrightYellow);
            return;
        }

        const capped = @min(length, 4096);
        if (capped < length) {
            self.log.println("Capped to 4096 bytes.", .{}, .BrightYellow);
        }

        // Validate that all pages in the range are mapped
        const end_addr = addr +% capped;
        if (end_addr < addr) {
            self.log.println("Address range wraps around.", .{}, .BrightRed);
            return;
        }

        var check = addr & ~@as(u64, 0xFFF); // page-align down
        while (check < end_addr) : (check += 4096) {
            if (!owos.vmm.is_mapped(check)) {
                self.log.print("Unmapped page at 0x{X:0>16}", .{check}, .BrightRed);
                self.log.println(" - aborting.", .{}, .BrightRed);
                return;
            }
        }

        self.log.println("0x{X:0>16}:", .{addr}, .Grey);
        const ptr: [*]const u8 = @ptrFromInt(addr);
        self.hex_dump("memory", ptr[0..capped], .BrightBlue, @truncate(addr));
    }

    fn parse_hex_u64(s: []const u8) ?u64 {
        const digits = if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
            s[2..]
        else
            s;
        if (digits.len == 0 or digits.len > 16) return null;
        return std.fmt.parseInt(u64, digits, 16) catch null;
    }

    fn cmd_ping(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: ping <ip>", .{}, .BrightYellow);
            return;
        }
        const ip = owos.net.parse_ip(self.tokens[1]) orelse {
            self.log.println("Invalid IP address.", .{}, .BrightRed);
            return;
        };
        if (!owos.e1000.ready) {
            self.log.println("Network not available.", .{}, .BrightRed);
            return;
        }
        var ip_buf: [15]u8 = undefined;
        const ip_str = owos.net.format_ip(ip, &ip_buf);
        self.log.print("PING {s} ...", .{ip_str}, .Grey);
        self.log.newline();
        rendering.swap();

        const result = owos.net.ping(ip);
        if (result) |r| {
            self.log.print("Reply from {s}", .{ip_str}, .BrightGreen);
            self.log.println("  ttl={d}", .{r.ttl}, .BrightBlue);
        } else {
            self.log.println("Request timed out.", .{}, .BrightRed);
        }
    }

    fn cmd_fs(self: *Shell) void {
        if (self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "reset")) {
            self.log.println("Resetting USB connection...", .{}, .Grey);
            owos.usb_storage.bot_reset();
            for (0..5_000_000) |_| asm volatile ("pause");
            if (owos.usb_storage.test_unit_ready_pub()) {
                self.log.println("USB device ready.", .{}, .BrightGreen);
            } else {
                self.log.println("USB device not responding. Try 'fs scan'.", .{}, .BrightRed);
            }
            return;
        }
        if (self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "scan")) {
            self.log.println("Scanning for storage devices...", .{}, .Grey);
            if (!owos.xhci.ready) owos.xhci.init();
            if (!owos.usb_storage.ready) owos.usb_storage.init();
            owos.owofs.scan();
            if (owos.owofs.partition_count == 0) {
                self.log.println("No partitions found.", .{}, .BrightRed);
            } else {
                self.log.println("{d} partition(s) found:", .{owos.owofs.partition_count}, .BrightGreen);
                for (owos.owofs.partitions[0..owos.owofs.partition_count], 0..) |p, i| {
                    const backend: []const u8 = if (p.backend_usb) "USB" else "AHCI";
                    const size_mb = if (p.sectors > 0) p.sectors / 2048 else 0;
                    self.log.print("  [{d}] ", .{i}, .BrightYellow);
                    self.log.print("{s}  LBA {d: >8}", .{ backend, p.lba }, .Grey);
                    if (size_mb > 0) {
                        self.log.print("  {d} MB", .{size_mb}, .Grey);
                    }
                    if (p.is_owofs) {
                        self.log.print("  OwOFS", .{}, .BrightGreen);
                        if (p.label_len > 0) {
                            self.log.print(" \"{s}\"", .{p.label[0..p.label_len]}, .BrightGreen);
                        }
                    } else {
                        self.log.print("  type=0x{X:0>2}", .{p.ptype}, .Grey);
                    }
                    self.log.println("", .{}, .White);
                }
                self.log.println("Use 'fs mount <N>' or 'fs format <N> [label]'.", .{}, .Grey);
            }
            return;
        }
        if (self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "format")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs format <N> [label]", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.partition_count == 0) {
                self.log.println("No partitions found. Run 'fs scan' first.", .{}, .BrightRed);
                return;
            }
            const idx = std.fmt.parseInt(usize, self.tokens[2], 10) catch {
                self.log.println("Invalid partition index.", .{}, .BrightRed);
                return;
            };
            if (idx >= owos.owofs.partition_count) {
                self.log.println("Partition index out of range.", .{}, .BrightRed);
                return;
            }
            const label = if (self.token_count >= 4) self.tokens[3] else "OwOS";
            if (owos.owofs.format_partition(idx, label)) {
                self.log.print("Formatted partition [{d}] as OwOFS: ", .{idx}, .BrightGreen);
                self.log.println("\"{s}\"", .{label}, .White);
            } else {
                self.log.println("Failed to format partition.", .{}, .BrightRed);
            }
            return;
        }
        if (self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "mount")) {
            if (owos.owofs.partition_count == 0) {
                self.log.println("Scanning for storage devices...", .{}, .Grey);
                if (!owos.xhci.ready) owos.xhci.init();
                if (!owos.usb_storage.ready) owos.usb_storage.init();
                owos.owofs.scan();
            }
            if (owos.owofs.partition_count == 0) {
                self.log.println("No partitions found.", .{}, .BrightRed);
                return;
            }
            const idx = if (self.token_count >= 3)
                std.fmt.parseInt(usize, self.tokens[2], 10) catch {
                    self.log.println("Invalid partition index.", .{}, .BrightRed);
                    return;
                }
            else blk: {
                // Auto-select first OwOFS partition
                for (owos.owofs.partitions[0..owos.owofs.partition_count], 0..) |p, i| {
                    if (p.is_owofs) break :blk i;
                }
                break :blk owos.owofs.partition_count - 1;
            };

            if (owos.owofs.mount_partition(idx)) {
                self.log.print("Mounted OwOFS partition [{d}]: ", .{idx}, .BrightGreen);
                self.log.println("\"{s}\"", .{owos.owofs.volume_label[0..owos.owofs.volume_label_len]}, .White);
            } else {
                self.log.println("Not an OwOFS partition. Use 'fs format <N>' first.", .{}, .BrightRed);
            }
            return;
        }
        if (self.token_count >= 2 and std.mem.eql(u8, self.tokens[1], "unmount")) {
            if (!owos.owofs.mounted) {
                self.log.println("Nothing is mounted.", .{}, .BrightYellow);
            } else {
                owos.owofs.unmount();
                self.log.println("Unmounted.", .{}, .BrightGreen);
            }
            return;
        }
        if (!owos.owofs.mounted) {
            self.log.println("No OwOFS partition mounted. Use 'fs scan' then 'fs mount <N>'.", .{}, .BrightRed);
            return;
        }
        if (self.token_count < 2) {
            self.log.println("Usage: fs <scan|format|mount|unmount|info|list|read|write|import|export|delete|mkdir|rmdir|rename|label>", .{}, .BrightYellow);
            return;
        }
        const sub = self.tokens[1];
        if (std.mem.eql(u8, sub, "info")) {
            self.log.print("Volume: ", .{}, .Grey);
            self.log.println("{s}", .{owos.owofs.volume_label[0..owos.owofs.volume_label_len]}, .BrightGreen);
            const total = owos.owofs.data_blocks();
            const free = owos.owofs.free_blocks();
            const used = total - free;
            self.log.print("Blocks: {d} total", .{total}, .BrightBlue);
            self.log.print("  {d} used", .{used}, .BrightYellow);
            self.log.println("  {d} free", .{free}, .BrightGreen);
            self.log.print("Capacity: ", .{}, .Grey);
            self.log.print("{d} KB total", .{total / 2}, .BrightBlue);
            self.log.println("  {d} KB free", .{free / 2}, .BrightGreen);
            self.log.println("Files: {d} / 1024", .{owos.owofs.file_count()}, .Grey);
        } else if (std.mem.eql(u8, sub, "list")) {
            const parent: u16 = if (self.token_count >= 3) blk: {
                const resolved = owos.owofs.resolve_path(self.tokens[2]) orelse {
                    self.log.println("Path not found.", .{}, .BrightRed);
                    return;
                };
                if (!resolved.entry.is_dir()) {
                    self.log.println("Not a directory.", .{}, .BrightRed);
                    return;
                }
                break :blk @intCast(resolved.index);
            } else 0xFFFF; // root

            const listing = owos.owofs.list_dir(parent);
            if (listing.entries.len == 0) {
                self.log.println("(empty directory)", .{}, .Grey);
                return;
            }
            for (listing.entries) |e| {
                if (e.is_dir()) {
                    self.log.print("  <DIR>  ", .{}, .BrightBlue);
                } else {
                    self.log.print("  {d: >7} ", .{e.size}, .Grey);
                }
                if (!e.is_dir() and e.is_encrypted()) {
                    self.log.print("[enc] ", .{}, .BrightMagenta);
                } else {
                    self.log.print("      ", .{}, .Grey);
                }
                self.log.println("{s}", .{e.get_name()}, .White);
            }
            self.log.println("{d} entries", .{listing.entries.len}, .Grey);
        } else if (std.mem.eql(u8, sub, "read")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs read <path>", .{}, .BrightYellow);
                return;
            }
            const resolved = owos.owofs.resolve_path(self.tokens[2]) orelse {
                self.log.println("File not found.", .{}, .BrightRed);
                return;
            };
            if (resolved.entry.is_dir()) {
                self.log.println("Cannot read a directory. Use 'fs list'.", .{}, .BrightYellow);
                return;
            }
            if (resolved.entry.size > 4096) {
                self.log.println("File too large (max 4096 bytes for display).", .{}, .BrightYellow);
                return;
            }
            const n = owos.owofs.read_file(resolved, &fs_io_buf) orelse {
                self.log.println("Read/decryption failed.", .{}, .BrightRed);
                return;
            };
            if (n == 0) {
                self.log.println("(empty file)", .{}, .Grey);
            } else {
                self.log.println("{s}", .{fs_io_buf[0..n]}, .White);
            }
        } else if (std.mem.eql(u8, sub, "write")) {
            if (self.token_count < 4) {
                self.log.println("Usage: fs write <path> <content> [--no-encrypt]", .{}, .BrightYellow);
                return;
            }
            const content = self.rest_after_token(2) orelse {
                self.log.println("Usage: fs write <path> <content>", .{}, .BrightYellow);
                return;
            };
            const no_enc = self.has_flag("--no-encrypt");
            if (owos.owofs.write_file(self.tokens[2], content, no_enc)) {
                self.log.print("Wrote {d} bytes to OwOFS: ", .{content.len}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[2]}, .White);
            } else {
                self.log.println("Failed to write file.", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "import")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs import <fspath> [ramfs_name]", .{}, .BrightYellow);
                return;
            }
            const resolved = owos.owofs.resolve_path(self.tokens[2]) orelse {
                self.log.println("File not found on OwOFS.", .{}, .BrightRed);
                return;
            };
            if (resolved.entry.is_dir()) {
                self.log.println("Cannot import a directory.", .{}, .BrightRed);
                return;
            }
            const name = if (self.token_count >= 4) self.tokens[3] else blk: {
                const src = self.tokens[2];
                var last_slash: usize = src.len;
                while (last_slash > 0) {
                    last_slash -= 1;
                    if (src[last_slash] == '/') {
                        last_slash += 1;
                        break;
                    }
                    if (last_slash == 0) break;
                }
                break :blk src[last_slash..];
            };
            if (name.len == 0) {
                self.log.println("Cannot derive filename from path.", .{}, .BrightRed);
                return;
            }
            const n = owos.owofs.read_file(resolved, &fs_io_buf) orelse {
                self.log.println("Read/decryption failed.", .{}, .BrightRed);
                return;
            };
            const file = ramfs.create_file(name) catch |e| {
                self.log.print("RAMFS error: ", .{}, .BrightRed);
                self.log.println("{s}", .{@errorName(e)}, .White);
                return;
            };
            _ = file.write(fs_io_buf[0..n]) catch |e| {
                self.log.print("Write error: ", .{}, .BrightRed);
                self.log.println("{s}", .{@errorName(e)}, .White);
                return;
            };
            self.log.print("Imported {d} bytes to RAMFS: ", .{n}, .BrightGreen);
            self.log.println("{s}", .{name}, .White);
        } else if (std.mem.eql(u8, sub, "export")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs export <ramfs_ref> [fspath] [--no-encrypt]", .{}, .BrightYellow);
                return;
            }
            const r = self.resolve_file(self.tokens[2]) orelse return;
            const data = r.file.read_all(&fs_io_buf) catch |e| {
                self.log.print("Read error: ", .{}, .BrightRed);
                self.log.println("{s}", .{@errorName(e)}, .White);
                return;
            };
            const no_enc = self.has_flag("--no-encrypt");
            // Determine destination path
            const fs_path = if (self.token_count >= 4 and !std.mem.eql(u8, self.tokens[3], "--no-encrypt")) blk: {
                const arg = self.tokens[3];
                if (arg.len > 0 and arg[arg.len - 1] == '/') {
                    const src_name = r.file.name();
                    const total = arg.len + src_name.len;
                    if (total > fs_path_buf.len) {
                        self.log.println("Path too long.", .{}, .BrightRed);
                        return;
                    }
                    @memcpy(fs_path_buf[0..arg.len], arg);
                    @memcpy(fs_path_buf[arg.len..][0..src_name.len], src_name);
                    break :blk fs_path_buf[0..total];
                }
                break :blk arg;
            } else blk: {
                const src_name = r.file.name();
                @memcpy(fs_path_buf[0..src_name.len], src_name);
                break :blk fs_path_buf[0..src_name.len];
            };

            if (owos.owofs.write_file(fs_path, data, no_enc)) {
                self.log.print("Exported {d} bytes to OwOFS: ", .{data.len}, .BrightGreen);
                self.log.println("{s}", .{fs_path}, .White);
            } else {
                self.log.println("Failed to write to OwOFS.", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "delete") or std.mem.eql(u8, sub, "rm")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs delete <path>", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.delete_file(self.tokens[2])) {
                self.log.print("Deleted: ", .{}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[2]}, .White);
            } else if (owos.owofs.rmdir(self.tokens[2])) {
                self.log.print("Removed directory: ", .{}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[2]}, .White);
            } else {
                self.log.println("Failed to delete. (Directory not empty?)", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "mkdir")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs mkdir <path>", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.mkdir(self.tokens[2])) {
                self.log.print("Created directory: ", .{}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[2]}, .White);
            } else {
                self.log.println("Failed to create directory.", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "rmdir")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs rmdir <path>", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.rmdir(self.tokens[2])) {
                self.log.print("Removed directory: ", .{}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[2]}, .White);
            } else {
                self.log.println("Failed to remove directory (must be empty).", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "rename")) {
            if (self.token_count < 4) {
                self.log.println("Usage: fs rename <path> <new_name>", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.rename(self.tokens[2], self.tokens[3])) {
                self.log.print("Renamed to: ", .{}, .BrightGreen);
                self.log.println("{s}", .{self.tokens[3]}, .White);
            } else {
                self.log.println("Failed to rename.", .{}, .BrightRed);
            }
        } else if (std.mem.eql(u8, sub, "label")) {
            if (self.token_count < 3) {
                self.log.println("Usage: fs label <new_label>", .{}, .BrightYellow);
                return;
            }
            if (owos.owofs.set_volume_label(self.tokens[2])) {
                self.log.print("Volume label set to: ", .{}, .BrightGreen);
                self.log.println("{s}", .{owos.owofs.volume_label[0..owos.owofs.volume_label_len]}, .White);
            } else {
                self.log.println("Failed to set volume label.", .{}, .BrightRed);
            }
        } else {
            self.log.println("Usage: fs <scan|format|mount|unmount|info|list|read|write|import|export|delete|mkdir|rmdir|rename|label>", .{}, .BrightYellow);
        }
    }

    fn cmd_wping(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: wping <host|ip> [port]", .{}, .BrightYellow);
            return;
        }
        if (!owos.e1000.ready) {
            self.log.println("Network not available.", .{}, .BrightRed);
            return;
        }

        const host = self.tokens[1];
        const port: u16 = if (self.token_count >= 3)
            std.fmt.parseInt(u16, self.tokens[2], 10) catch {
                self.log.println("Invalid port number.", .{}, .BrightRed);
                return;
            }
        else
            80;

        // Show resolving step if it looks like a hostname
        const is_hostname = owos.net.parse_ip(host) == null;
        if (is_hostname) {
            self.log.print("Resolving {s} ...", .{host}, .Grey);
            self.log.newline();
            rendering.swap();
        }

        self.log.print("Connecting to {s}:{d} ...", .{ host, port }, .Grey);
        self.log.newline();
        rendering.swap();

        const result = owos.net.wping(host, port);
        if (result) |r| {
            const line = r.status_line[0..r.status_len];
            self.log.println("{s}", .{line}, .BrightGreen);
            if (r.status_code >= 200 and r.status_code < 400) {
                self.log.println("Web ping OK", .{}, .BrightGreen);
            } else {
                self.log.print("Web ping returned status ", .{}, .BrightYellow);
                self.log.println("{d}", .{r.status_code}, .BrightYellow);
            }
        } else {
            if (is_hostname and owos.net.parse_ip(host) == null) {
                self.log.println("Failed (DNS resolution, connection, or timeout).", .{}, .BrightRed);
            } else {
                self.log.println("Connection failed or timed out.", .{}, .BrightRed);
            }
        }
    }

    fn cmd_befo(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: befo <filename>", .{}, .BrightYellow);
            return;
        }
        const fname = self.tokens[1];
        var ed = &owos.editor.Editor.instance;
        ed.open(fname);
        ed.run();
        // Redraw the shell and print goodbye message after editor exits
        rendering.draw_rect(0, 0, rendering.GFB_WIDTH, rendering.GFB_HEIGHT, 0x000000);
        self.log.redraw_scrolled();
        self.log.print("BEFO: ", .{}, .Grey);
        self.log.println("Goodbye! :3", .{}, .White);
    }

    fn cmd_masterkey(self: *Shell) void {
        self.hex_dump("master_key", &ramfs.master_key, .BrightRed, 0);
    }

    fn cmd_dump(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: dump <ref> [--keys]", .{}, .BrightYellow);
            return;
        }
        const r = self.resolve_file(self.tokens[1]) orelse return;
        const file = r.file;
        const show_keys = self.has_flag("--keys");
        if (file.size == 0) {
            self.log.println("(empty file)", .{}, .Grey);
            return;
        }
        const tag_len = 16;
        const enc_total = file.size + tag_len;
        self.log.print("File: ", .{}, .Grey);
        self.log.print("{s} [#{d}]", .{ file.name(), r.index }, .White);
        self.log.println("  plaintext_size={d}  writes={d}", .{ file.size, file.write_count }, .Grey);
        var base: usize = 0;
        self.hex_dump("nonce", &file.nonce, .BrightMagenta, base);
        base += file.nonce.len;
        if (show_keys) {
            self.hex_dump("key", file.key, .BrightRed, base);
        } else {
            self.log.println("key ({d} bytes): <redacted> (use --keys to reveal)", .{file.key.len}, .BrightRed);
        }
        base += file.key.len;
        self.hex_dump("ciphertext", file.enc_data[0..file.size], .BrightBlue, base);
        base += file.size;
        self.hex_dump("tag", file.enc_data[file.size..enc_total], .BrightYellow, base);
        self.log.println("{d} bytes total (nonce + key + ciphertext + tag)", .{file.nonce.len + file.key.len + enc_total}, .Grey);
    }

    pub fn feed(self: *Shell, scancode: u8) void {
        const event = owos.ps2.process(scancode) orelse return;

        if (event.arrow_up) {
            self.log.scroll_up();
            return;
        }
        if (event.arrow_down) {
            self.log.scroll_down();
            return;
        }

        const c = event.char orelse return;

        // Any typed input snaps back to the live view
        if (self.log.scroll_offset > 0) {
            self.log.scroll_offset = 0;
            self.log.redraw_scrolled();
        }

        if (c == '\n') {
            self.log.newline();
            self.execute();
            self.prompt();
            rendering.swap();
        } else if (c == 0x08) {
            if (self.len > 0) {
                self.len -= 1;
                self.log.backspace();
                rendering.swap();
            }
        } else {
            if (self.len < max_input) {
                self.buf[self.len] = c;
                self.len += 1;
                self.log.print("{c}", .{c}, C.White);
                rendering.swap();
            }
        }
    }

    pub fn run(self: *Shell) noreturn {
        while (true) {
            if (owos.ps2.poll()) |scancode| {
                self.feed(scancode);
            }
        }
    }
};
