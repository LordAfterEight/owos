const std = @import("std");
const owos = @import("root.zig");
const rendering = owos.fb.rendering;
const C = rendering.Color;

const ramfs = owos.ramfs;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const max_input = 256;
const max_tokens = 32;

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
            const start = i;
            while (i < input.len and input[i] != ' ') i += 1;
            self.tokens[self.token_count] = input[start..i];
            self.token_count += 1;
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
            self.log.println("befo <filename>                     Open vim-style editor (Basic Editor For OwOS)", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("new <arg>                           Create a new object of type <arg>", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("write <ref> <content>               Append text to a file", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("read <ref>                          Print file contents as text", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("dump <ref> [--keys]                 Hex dump (--keys to include keys)", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("delete <ref>                        Delete a file", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("list                                List all files", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("memdump <region|addr> [n]           Dump raw memory ('memdump regions')", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("masterkey                           Display the master encryption key", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("clear                               Clear the screen", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("lockdown <passphrase>               Lock system, generate one-time code", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("unlock <pass> <code>                Unlock (2 failures = wipe)", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("serial on|off                       Toggle serial output", .{}, .BrightMagenta);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("verbosity [quiet|normal|verbose]    Set logging verbosity", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("layout [qwerty|qwertz]              Set keyboard layout", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("shutdown                            Power off the machine", .{}, .BrightBlue);
            self.log.print("  - ", .{}, .Grey);
            self.log.println("reboot                              Restart the machine", .{}, .BrightBlue);
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

    fn cmd_befo(self: *Shell) void {
        if (self.token_count < 2) {
            self.log.println("Usage: befo <filename>", .{}, .BrightYellow);
            return;
        }
        const fname = self.tokens[1];
        var ed = &owos.editor.Editor.instance;
        ed.open(fname);
        ed.run();
        // Redraw the shell after editor exits
        rendering.draw_rect(0, 0, rendering.GFB_WIDTH, rendering.GFB_HEIGHT, 0x000000);
        self.log.redraw_scrolled();
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
