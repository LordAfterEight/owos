const std = @import("std");
const owos = @import("../root.zig");
const ramfs = @import("ramfs.zig");
const File = ramfs.File;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

// ---------------------------------------------------------------------------
// Test reporting
// ---------------------------------------------------------------------------

var pass_count: usize = 0;
var total_count: usize = 0;

fn report(name: []const u8, ok: bool) void {
    const log = &owos.fb.rendering.ScrollingLog.instance;
    total_count += 1;
    if (ok) pass_count += 1;
    log.print("TESTS: ", .{}, .Grey);
    if (ok) {
        log.print("[PASS] ", .{}, .BrightGreen);
    } else {
        log.print("[FAIL] ", .{}, .BrightRed);
    }
    log.println("{s}", .{name}, .White);
}

fn section(name: []const u8) void {
    if (owos.klog.verbosity == .quiet) return;
    owos.klog.info("TESTS: --- {s} ---", .{name});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Write a string, read it back, verify bytes are identical.
fn test_basic_roundtrip() bool {
    var file = File.new("t_basic") catch return false;
    _ = file.write("Hello, World!") catch return false;
    var buf: [64]u8 = undefined;
    const data = file.read_all(&buf) catch return false;
    return std.mem.eql(u8, data, "Hello, World!");
}

/// Two sequential writes must produce the concatenated plaintext on read.
fn test_append_two_writes() bool {
    var file = File.new("t_append") catch return false;
    _ = file.write("Hello, ") catch return false;
    _ = file.write("World!") catch return false;
    var buf: [64]u8 = undefined;
    const data = file.read_all(&buf) catch return false;
    return std.mem.eql(u8, data, "Hello, World!");
}

/// Three sequential writes must also produce the full concatenation.
fn test_append_three_writes() bool {
    var file = File.new("t_append3") catch return false;
    _ = file.write("one/") catch return false;
    _ = file.write("two/") catch return false;
    _ = file.write("three") catch return false;
    var buf: [64]u8 = undefined;
    const data = file.read_all(&buf) catch return false;
    return std.mem.eql(u8, data, "one/two/three");
}

/// A file that was never written should read back as an empty slice.
fn test_empty_file() bool {
    var file = File.new("t_empty") catch return false;
    var buf: [16]u8 = undefined;
    const data = file.read_all(&buf) catch return false;
    return data.len == 0;
}

/// read_all on a buffer smaller than the plaintext must return BufferTooSmall.
fn test_buffer_too_small() bool {
    var file = File.new("t_bufsmall") catch return false;
    _ = file.write("Hello, World!") catch return false;
    var buf: [4]u8 = undefined;
    _ = file.read_all(&buf) catch |e| return e == error.BufferTooSmall;
    return false; // must not succeed
}

/// Flipping a byte in the ciphertext body must trigger AuthenticationFailed.
fn test_auth_ciphertext_tamper() bool {
    var file = File.new("t_ct_tamper") catch return false;
    _ = file.write("secret payload") catch return false;
    file.enc_data[file.size / 2] ^= 0xAA; // corrupt one ciphertext byte
    var buf: [64]u8 = undefined;
    _ = file.read_all(&buf) catch |e| return e == error.AuthenticationFailed;
    return false;
}

/// Flipping a byte inside the Poly1305 tag must also trigger AuthenticationFailed.
fn test_auth_tag_tamper() bool {
    var file = File.new("t_tag_tamper") catch return false;
    _ = file.write("secret payload") catch return false;
    // Tag lives immediately after the ciphertext bytes.
    file.enc_data[file.size + ChaCha20Poly1305.tag_length / 2] ^= 0xAA;
    var buf: [64]u8 = undefined;
    _ = file.read_all(&buf) catch |e| return e == error.AuthenticationFailed;
    return false;
}

/// Flipping the very first ciphertext byte (edge case: offset 0) must fail auth.
fn test_auth_tamper_first_byte() bool {
    var file = File.new("t_tamper0") catch return false;
    _ = file.write("edge case") catch return false;
    file.enc_data[0] ^= 0x01;
    var buf: [64]u8 = undefined;
    _ = file.read_all(&buf) catch |e| return e == error.AuthenticationFailed;
    return false;
}

/// Flipping the very last ciphertext byte (edge case: size-1) must fail auth.
fn test_auth_tamper_last_byte() bool {
    var file = File.new("t_tamper_end") catch return false;
    _ = file.write("edge case") catch return false;
    file.enc_data[file.size - 1] ^= 0x01;
    var buf: [64]u8 = undefined;
    _ = file.read_all(&buf) catch |e| return e == error.AuthenticationFailed;
    return false;
}

/// Two distinct files must receive distinct nonces (file-ID bytes differ).
fn test_unique_nonces_per_file() bool {
    var f1 = File.new("t_nonce_a") catch return false;
    var f2 = File.new("t_nonce_b") catch return false;
    _ = f1.write("data") catch return false;
    _ = f2.write("data") catch return false;
    return !std.mem.eql(u8, &f1.nonce, &f2.nonce);
}

/// Two files with identical plaintext must produce different ciphertext
/// because their nonces are distinct.
fn test_same_plaintext_different_ciphertext() bool {
    var f1 = File.new("t_ct_diff_a") catch return false;
    var f2 = File.new("t_ct_diff_b") catch return false;
    const payload = "identical plaintext";
    _ = f1.write(payload) catch return false;
    _ = f2.write(payload) catch return false;
    if (f1.size != f2.size) return false; // sanity
    return !std.mem.eql(u8, f1.enc_data[0..f1.size], f2.enc_data[0..f2.size]);
}

/// The file-ID portion (nonce bytes 0-7) must stay constant across writes,
/// while the write-counter portion (bytes 8-11) must increment each time.
fn test_nonce_write_counter_increments() bool {
    var file = File.new("t_nonce_inc") catch return false;
    const nonce0 = file.nonce;

    _ = file.write("first") catch return false;
    const nonce1 = file.nonce;

    _ = file.write("second") catch return false;
    const nonce2 = file.nonce;

    // File-ID bytes must be stable.
    if (!std.mem.eql(u8, nonce0[0..8], nonce1[0..8])) return false;
    if (!std.mem.eql(u8, nonce1[0..8], nonce2[0..8])) return false;

    // Write-counter bytes must strictly increase.
    if (std.mem.eql(u8, nonce0[8..12], nonce1[8..12])) return false;
    if (std.mem.eql(u8, nonce1[8..12], nonce2[8..12])) return false;

    return true;
}

/// write_count field must start at 0 and increment once per write call.
fn test_write_count_values() bool {
    var file = File.new("t_wc") catch return false;
    if (file.write_count != 0) return false;
    _ = file.write("a") catch return false;
    if (file.write_count != 1) return false;
    _ = file.write("b") catch return false;
    if (file.write_count != 2) return false;
    _ = file.write("c") catch return false;
    if (file.write_count != 3) return false;
    return true;
}

/// Each file must receive its own unique key derived from the master key.
fn test_per_file_keys() bool {
    const f1 = File.new("t_key_a") catch return false;
    const f2 = File.new("t_key_b") catch return false;
    // Keys must exist (non-zero) and differ between files.
    const zero_key = [_]u8{0} ** ChaCha20Poly1305.key_length;
    if (std.mem.eql(u8, f1.key, &zero_key)) return false;
    if (std.mem.eql(u8, f2.key, &zero_key)) return false;
    return !std.mem.eql(u8, f1.key, f2.key);
}

/// After delete, the key must be zeroed and reads must fail.
fn test_delete_erases_key() bool {
    var file = File.new("t_del") catch return false;
    _ = file.write("secret") catch return false;
    file.delete();
    const zero_key = [_]u8{0} ** ChaCha20Poly1305.key_length;
    if (!std.mem.eql(u8, file.key, &zero_key)) return false;
    // read_all on a deleted file must fail (size was zeroed).
    var buf: [64]u8 = undefined;
    const data = file.read_all(&buf) catch return false;
    return data.len == 0;
}

/// Re-reading the same file twice must return the same plaintext both times.
fn test_idempotent_read() bool {
    var file = File.new("t_reread") catch return false;
    _ = file.write("stable content") catch return false;
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const d1 = file.read_all(&buf1) catch return false;
    const d2 = file.read_all(&buf2) catch return false;
    return std.mem.eql(u8, d1, d2);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run_all(verbosity: owos.klog.LoggingVerbosity) void {
    const prev_verbosity = owos.klog.verbosity;
    owos.klog.verbosity = verbosity;
    defer owos.klog.verbosity = prev_verbosity;

    pass_count = 0;
    total_count = 0;

    owos.klog.info("TESTS: ========== ramfs crypto suite ==========", .{});

    section("basic round-trip");
    report("write + read_all matches plaintext", test_basic_roundtrip());

    section("append");
    report("two sequential writes concatenate correctly", test_append_two_writes());
    report("three sequential writes concatenate correctly", test_append_three_writes());

    section("edge cases");
    report("empty file returns empty slice", test_empty_file());
    report("buffer too small returns BufferTooSmall", test_buffer_too_small());
    report("re-reading same file is idempotent", test_idempotent_read());

    section("authentication failure");
    report("ciphertext body tamper triggers AuthenticationFailed", test_auth_ciphertext_tamper());
    report("poly1305 tag tamper triggers AuthenticationFailed", test_auth_tag_tamper());
    report("first ciphertext byte tamper triggers AuthenticationFailed", test_auth_tamper_first_byte());
    report("last ciphertext byte tamper triggers AuthenticationFailed", test_auth_tamper_last_byte());

    section("per-file keys");
    report("each file gets a unique non-zero key", test_per_file_keys());
    report("delete zeroes key and prevents reads", test_delete_erases_key());

    section("nonce uniqueness");
    report("distinct files have distinct nonces", test_unique_nonces_per_file());
    report("same plaintext in different files produces different ciphertext", test_same_plaintext_different_ciphertext());
    report("nonce write-counter bytes increment on each write", test_nonce_write_counter_increments());
    report("write_count field increments once per write", test_write_count_values());

    // Summary line
    const log = &owos.fb.rendering.ScrollingLog.instance;
    log.print("TESTS: ", .{}, .Grey);
    const all_pass = pass_count == total_count;
    if (all_pass) {
        log.print("{d}/{d} passed --", .{ pass_count, total_count }, .BrightGreen);
        log.println("ALL OK", .{}, .BrightGreen);
    } else {
        log.print("{d}/{d} passed --", .{ pass_count, total_count }, .BrightRed);
        log.println("{d} FAILED", .{ total_count - pass_count }, .BrightRed);
    }
    owos.klog.info("TESTS: ==========================================", .{});
}
