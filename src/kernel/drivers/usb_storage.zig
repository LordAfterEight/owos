const std = @import("std");
const owos = @import("../root.zig");
const xhci = owos.xhci;

pub var ready: bool = false;
var tag: u32 = 1;

pub fn init() void {
    ready = false;
    if (!xhci.ready) return;

    // TEST UNIT READY — some devices need a few attempts
    var ok = false;
    for (0..3) |_| {
        if (test_unit_ready()) {
            ok = true;
            break;
        }
    }
    if (!ok) {
        owos.klog.warn("USB-MSC: device not ready", .{});
        return;
    }

    ready = true;
    owos.klog.info("USB-MSC: ready", .{});
}

// ── CBW / CSW ──────────────────────────────────────────────────────────

fn send_cbw(data_len: u32, flags: u8, cb: [16]u8, cb_len: u8) bool {
    var cbw: [31]u8 = undefined;
    cbw[0] = 0x55;
    cbw[1] = 0x53;
    cbw[2] = 0x42;
    cbw[3] = 0x43; // "USBC"
    std.mem.writeInt(u32, cbw[4..8], tag, .little);
    std.mem.writeInt(u32, cbw[8..12], data_len, .little);
    cbw[12] = flags;
    cbw[13] = 0; // LUN
    cbw[14] = cb_len;
    @memcpy(cbw[15..31], cb[0..16]);
    tag +%= 1;
    return xhci.bulk_out(&cbw) != null;
}

fn recv_csw() bool {
    var csw: [13]u8 = undefined;
    const n = xhci.bulk_in(&csw) orelse return false;
    if (n < 13) return false;
    if (csw[0] != 0x55 or csw[1] != 0x53 or csw[2] != 0x42 or csw[3] != 0x53) return false;
    return csw[12] == 0; // bCSWStatus == Passed
}

fn test_unit_ready() bool {
    const cb: [16]u8 = .{0} ** 16;
    if (!send_cbw(0, 0, cb, 6)) return false;
    return recv_csw();
}

pub fn test_unit_ready_pub() bool {
    return test_unit_ready();
}

/// Perform a Bulk-Only Mass Storage Reset (class-specific request)
/// followed by clearing HALT on both bulk endpoints.
/// This resyncs the CBW/Data/CSW protocol state.
pub fn bot_reset() void {
    // BOT Reset: bmRequestType=0x21 (class, interface), bRequest=0xFF
    _ = xhci.ctrl_out_nodata(0x21, 0xFF, 0, 0);
    // Clear HALT on bulk endpoints
    _ = xhci.ctrl_out_nodata(0x02, 1, 0, @as(u16, @truncate(xhci.bi_dci / 2)) | 0x80); // CLEAR_FEATURE(HALT) bulk IN
    _ = xhci.ctrl_out_nodata(0x02, 1, 0, @as(u16, @truncate(xhci.bo_dci / 2))); // CLEAR_FEATURE(HALT) bulk OUT
    tag +%= 1;
}

pub fn sync_cache() void {
    var cb: [16]u8 = .{0} ** 16;
    cb[0] = 0x35; // SYNCHRONIZE CACHE(10)
    if (!send_cbw(0, 0, cb, 10)) return;
    // CSW may take a while as the device flushes its internal cache.
    // recv_csw uses wait_xfer which has a generous timeout.
    _ = recv_csw();
}

// ── Sector I/O ─────────────────────────────────────────────────────────

fn read_one(lba: u64, count: u32, out: []u8) bool {
    const bytes: u32 = count * 512;
    var cb: [16]u8 = .{0} ** 16;
    cb[0] = 0x28; // READ(10)
    std.mem.writeInt(u32, cb[2..6], @truncate(lba), .big);
    std.mem.writeInt(u16, cb[7..9], @truncate(count), .big);

    if (!send_cbw(bytes, 0x80, cb, 10)) return false;
    _ = xhci.bulk_in(out[0 .. bytes]) orelse return false;
    return recv_csw();
}

pub fn read_sectors(lba: u64, count: u32, out: []u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;

    while (remaining > 0) {
        const chunk: u32 = @min(remaining, 8);
        const bytes: usize = @as(usize, chunk) * 512;

        var ok = false;
        for (0..5) |attempt| {
            if (read_one(cur_lba, chunk, out[offset..][0..bytes])) {
                ok = true;
                break;
            }
            for (0..2_000_000) |_| asm volatile ("pause");
            if (attempt == 2) {
                bot_reset();
            } else {
                _ = test_unit_ready();
            }
        }
        if (!ok) {
            if (!xhci.is_connected()) ready = false;
            return false;
        }

        offset += bytes;
        remaining -= chunk;
        cur_lba += chunk;
    }
    return true;
}

fn write_chunk(lba: u64, count: u32, data: []const u8) bool {
    const bytes: u32 = count * 512;
    var cb: [16]u8 = .{0} ** 16;
    cb[0] = 0x2A; // WRITE(10)
    std.mem.writeInt(u32, cb[2..6], @truncate(lba), .big);
    std.mem.writeInt(u16, cb[7..9], @truncate(count), .big);

    if (!send_cbw(bytes, 0x00, cb, 10)) return false;
    _ = xhci.bulk_out(data[0..bytes]) orelse return false;
    return recv_csw();
}

pub fn write_sectors(lba: u64, count: u32, data: []const u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;
    var since_sync: u32 = 0;

    while (remaining > 0) {
        // Write one sector at a time — many USB sticks stall on multi-sector
        // writes when their internal buffer fills up.
        var buf: [512]u8 = .{0} ** 512;
        if (offset < data.len) {
            const copy = @min(512, data.len - offset);
            @memcpy(buf[0..copy], data[offset..][0..copy]);
        }

        var ok = false;
        for (0..8) |attempt| {
            if (write_chunk(cur_lba, 1, &buf)) {
                ok = true;
                break;
            }
            for (0..5_000_000) |_| asm volatile ("pause");
            if (attempt == 3) {
                // Mid-way: try a BOT reset to resync protocol state
                bot_reset();
            } else if (attempt < 7) {
                _ = test_unit_ready();
            }
        }
        if (!ok) {
            owos.klog.warn("USB-MSC: WRITE failed lba={d} after retries", .{cur_lba});
            if (!xhci.is_connected()) ready = false;
            return false;
        }

        offset += 512;
        remaining -= 1;
        cur_lba += 1;
        since_sync += 1;

        if (since_sync >= 8) {
            sync_cache();
            since_sync = 0;
        }
    }
    return true;
}
