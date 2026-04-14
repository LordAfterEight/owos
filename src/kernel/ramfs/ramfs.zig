const std = @import("std");
pub const owos = @import("../root.zig");
pub const crypto_tests = @import("crypto_tests.zig");

const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const RAMFS_BASE: usize = 0xffff900000000000;
pub const RAMFS_SIZE: usize = 0x1_0000_0000;

var bump: usize = 0;
var master_key: [ChaCha20Poly1305.key_length]u8 = undefined;
var file_id_counter: u64 = 0;

fn bump_alloc(n: usize) []u8 {
    const base: [*]u8 = @ptrFromInt(RAMFS_BASE);
    const slice = base[bump .. bump + n];
    bump += n;
    return slice;
}

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

/// Prints "RAMFS: <label>" in Grey then each byte of `bytes` as "xx " in BrightBlue.
/// Only emits output when klog verbosity is `.verbose`.
fn log_bytes(label: []const u8, bytes: []const u8) void {
    if (owos.klog.verbosity != .verbose) return;
    const log = &owos.fb.rendering.ScrollingLog.instance;
    const C = owos.fb.rendering.Color;
    log.print("RAMFS: ", .{}, .Grey);
    log.print("{s}", .{label}, .White);
    var buf: [3]u8 = undefined;
    for (bytes) |b| {
        const s = std.fmt.bufPrint(&buf, "{x:0>2} ", .{b}) catch buf[0..];
        log.print("{s}", .{s}, C.BrightBlue);
    }
    log.newline();
}

// ---------------------------------------------------------------------------
// Module init
// ---------------------------------------------------------------------------

/// Zero the RAMFS region and store the master encryption key.
/// The key should be sourced from hardware entropy (e.g. RDRAND) in production.
pub fn init(key: [ChaCha20Poly1305.key_length]u8) void {
    const base: [*]u8 = @ptrFromInt(RAMFS_BASE);
    @memset(base[0..RAMFS_SIZE], 0);
    master_key = key;

    if (owos.klog.verbosity == .verbose) {
        owos.klog.info("RAMFS: init  base={x:0>16}  size={x:0>8}  key_len={d}B  tag_len={d}B  nonce_len={d}B", .{
            RAMFS_BASE,
            RAMFS_SIZE,
            ChaCha20Poly1305.key_length,
            ChaCha20Poly1305.tag_length,
            ChaCha20Poly1305.nonce_length,
        });
        log_bytes("master_key= ", &master_key);
    }
}

// ---------------------------------------------------------------------------
// File
// ---------------------------------------------------------------------------

pub const File = struct {
    name_buf: [32]u8,
    name_len: usize,
    /// Plaintext byte count (does not include the authentication tag).
    size: usize,
    /// Ciphertext followed immediately by the 16-byte Poly1305 tag.
    enc_data: []u8,
    /// 12-byte nonce: [8 B file ID (LE)][4 B write counter (LE)].
    nonce: [ChaCha20Poly1305.nonce_length]u8,
    write_count: u32,
    /// Per-file encryption key, derived from the master key and the file ID.
    /// Stored in the RAMFS bump-allocated region (not on the stack) to avoid
    /// key copies lingering in stack frames.  Zeroed on delete.
    key: *[ChaCha20Poly1305.key_length]u8,

    /// Derives a per-file key by encrypting a zero block with the master key
    /// and a nonce built from the file ID (with the write-counter portion set
    /// to 0xFFFFFFFF so it can never collide with a data nonce).
    /// The key is written directly into `dst` to avoid intermediate stack copies.
    fn derive_key(id: u64, dst: *[ChaCha20Poly1305.key_length]u8) void {
        var kdf_nonce = [_]u8{0} ** ChaCha20Poly1305.nonce_length;
        std.mem.writeInt(u64, kdf_nonce[0..8], id, .little);
        std.mem.writeInt(u32, kdf_nonce[8..12], 0xFFFFFFFF, .little);

        var kdf_tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        const zero_block = [_]u8{0} ** ChaCha20Poly1305.key_length;
        ChaCha20Poly1305.encrypt(dst, &kdf_tag, &zero_block, &.{}, kdf_nonce, master_key);
        @memset(&kdf_tag, 0);
        @memset(&kdf_nonce, 0);
    }

    pub fn new(n: []const u8) !File {
        if (n.len > 32) return error.FilenameTooLong;

        var nonce = [_]u8{0} ** ChaCha20Poly1305.nonce_length;
        const id = file_id_counter;
        file_id_counter += 1;
        std.mem.writeInt(u64, nonce[0..8], id, .little);

        // Allocate the key in the RAMFS region so it never lives on the stack.
        const key_buf: *[ChaCha20Poly1305.key_length]u8 = @ptrCast(bump_alloc(ChaCha20Poly1305.key_length).ptr);
        derive_key(id, key_buf);

        var file: File = .{
            .name_buf = [_]u8{0} ** 32,
            .name_len = n.len,
            .size = 0,
            .enc_data = bump_alloc(0),
            .nonce = nonce,
            .write_count = 0,
            .key = key_buf,
        };
        @memcpy(file.name_buf[0..n.len], n);

        if (owos.klog.verbosity == .verbose) {
            owos.klog.info("RAMFS: new \"{s}\"  file_id={d}  write_count={d}", .{ file.name(), id, file.write_count });
            log_bytes("initial_nonce= ", &file.nonce);
            log_bytes("file_key= ", file.key);
        }

        return file;
    }

    /// Securely erases the per-file key and zeroes the ciphertext, preventing
    /// any further reads or writes.
    pub fn delete(self: *File) void {
        if (owos.klog.verbosity == .verbose) {
            owos.klog.info("RAMFS: delete \"{s}\"  erasing key + {d}B ciphertext", .{ self.name(), self.size });
        }
        @memset(self.key, 0);
        if (self.size > 0) {
            @memset(self.enc_data[0 .. self.size + ChaCha20Poly1305.tag_length], 0);
        }
        self.size = 0;
    }

    pub fn name(self: *const File) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Appends `buf` to the file.  Existing ciphertext is decrypted, the new
    /// data is appended in plaintext, and the combined content is re-encrypted
    /// under a fresh nonce (write counter incremented) before storing.
    pub fn write(self: *File, buf: []const u8) !usize {
        const new_size = self.size + buf.len;
        const new_enc_size = new_size + ChaCha20Poly1305.tag_length;

        const log_verbose = owos.klog.verbosity == .verbose;

        if (log_verbose) {
            owos.klog.info("RAMFS: write \"{s}\"  existing={d}B  appending={d}B  new_total={d}B", .{
                self.name(), self.size, buf.len, new_size,
            });
            log_bytes("write_data= ", buf);
        }

        // Staging buffer for combined plaintext (bump-allocated; never freed).
        const plaintext = bump_alloc(new_size);

        if (self.size > 0) {
            if (log_verbose) owos.klog.info("RAMFS: decrypting existing {d}B before append", .{self.size});

            var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
            @memcpy(&tag, self.enc_data[self.size .. self.size + ChaCha20Poly1305.tag_length]);

            log_bytes("  decrypt.nonce= ", &self.nonce);
            log_bytes("  decrypt.ciphertext= ", self.enc_data[0..self.size]);
            log_bytes("  decrypt.tag= ", &tag);

            try ChaCha20Poly1305.decrypt(
                plaintext[0..self.size],
                self.enc_data[0..self.size],
                tag,
                &.{},
                self.nonce,
                self.key.*,
            );

            log_bytes("  decrypt.plaintext= ", plaintext[0..self.size]);
        }

        @memcpy(plaintext[self.size..new_size], buf);

        // Advance the write counter so this encryption uses a fresh nonce.
        self.write_count += 1;
        std.mem.writeInt(u32, self.nonce[8..12], self.write_count, .little);

        if (log_verbose) owos.klog.info("RAMFS: write_count now {d}  nonce updated", .{self.write_count});
        log_bytes("combined_plaintext= ", plaintext);
        log_bytes("encrypt.nonce= ", &self.nonce);

        const new_enc_data = bump_alloc(new_enc_size);
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        ChaCha20Poly1305.encrypt(
            new_enc_data[0..new_size],
            &tag,
            plaintext,
            &.{},
            self.nonce,
            self.key.*,
        );
        @memcpy(new_enc_data[new_size..new_enc_size], &tag);

        // Zero the plaintext staging buffer — it held decrypted content.
        @memset(plaintext, 0);

        log_bytes("encrypt.ciphertext= ", new_enc_data[0..new_size]);
        log_bytes("encrypt.tag= ", &tag);
        if (log_verbose) owos.klog.info("RAMFS: stored {d}B ciphertext + {d}B tag at bump+{x:0>8}", .{
            new_size, ChaCha20Poly1305.tag_length, bump - new_enc_size,
        });

        self.enc_data = new_enc_data;
        self.size = new_size;
        return buf.len;
    }

    /// Decrypts the file into `out` and returns the filled slice.
    /// `out` must be at least `self.size` bytes.
    /// Returns `error.AuthenticationFailed` if the ciphertext has been tampered with.
    pub fn read_all(self: *const File, out: []u8) ![]const u8 {
        if (self.size == 0) return out[0..0];
        if (out.len < self.size) return error.BufferTooSmall;

        const log_verbose = owos.klog.verbosity == .verbose;

        if (log_verbose) owos.klog.info("RAMFS: read_all \"{s}\"  size={d}B  enc_size={d}B", .{
            self.name(), self.size, self.size + ChaCha20Poly1305.tag_length,
        });

        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        @memcpy(&tag, self.enc_data[self.size .. self.size + ChaCha20Poly1305.tag_length]);

        log_bytes("decrypt.nonce= ", &self.nonce);
        log_bytes("decrypt.ciphertext= ", self.enc_data[0..self.size]);
        log_bytes("decrypt.tag= ", &tag);

        try ChaCha20Poly1305.decrypt(
            out[0..self.size],
            self.enc_data[0..self.size],
            tag,
            &.{},
            self.nonce,
            self.key.*,
        );

        log_bytes("decrypt.plaintext= ", out[0..self.size]);
        if (log_verbose) owos.klog.info("RAMFS: auth tag verified  decryption successful", .{});

        return out[0..self.size];
    }
};
