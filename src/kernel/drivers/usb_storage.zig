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
    const n = xhci.bulk_in(&csw) orelse {
        ready = false;
        return false;
    };
    if (n < 13) return false;
    if (csw[0] != 0x55 or csw[1] != 0x53 or csw[2] != 0x42 or csw[3] != 0x53) return false;
    return csw[12] == 0; // bCSWStatus == Passed
}

fn test_unit_ready() bool {
    const cb: [16]u8 = .{0} ** 16;
    if (!send_cbw(0, 0, cb, 6)) return false;
    return recv_csw();
}

fn sync_cache() void {
    var cb: [16]u8 = .{0} ** 16;
    cb[0] = 0x35; // SYNCHRONIZE CACHE(10)
    if (send_cbw(0, 0, cb, 10)) _ = recv_csw();
}

// ── Sector I/O ─────────────────────────────────────────────────────────

pub fn read_sectors(lba: u64, count: u32, out: []u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;

    while (remaining > 0) {
        const chunk: u32 = @min(remaining, 8);
        const bytes: usize = @as(usize, chunk) * 512;

        var cb: [16]u8 = .{0} ** 16;
        cb[0] = 0x28; // READ(10)
        std.mem.writeInt(u32, cb[2..6], @truncate(cur_lba), .big);
        std.mem.writeInt(u16, cb[7..9], @truncate(chunk), .big);

        if (!send_cbw(@truncate(bytes), 0x80, cb, 10)) {
            ready = false;
            return false;
        }

        const copy = @min(bytes, out.len - offset);
        const got = xhci.bulk_in(out[offset..][0..copy]) orelse {
            ready = false;
            return false;
        };
        _ = got;

        if (!recv_csw()) return false;

        offset += bytes;
        remaining -= chunk;
        cur_lba += chunk;
    }
    return true;
}

fn write_one_sector(lba: u64, sector: *[512]u8) bool {
    var cb: [16]u8 = .{0} ** 16;
    cb[0] = 0x2A; // WRITE(10)
    std.mem.writeInt(u32, cb[2..6], @truncate(lba), .big);
    std.mem.writeInt(u16, cb[7..9], @as(u16, 1), .big);

    if (!send_cbw(512, 0x00, cb, 10)) return false;
    _ = xhci.bulk_out(sector) orelse return false;
    return recv_csw();
}

pub fn write_sectors(lba: u64, count: u32, data: []const u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;

    // Write one sector at a time with retry for transient USB failures
    while (remaining > 0) {
        var sector: [512]u8 = .{0} ** 512;
        if (offset < data.len) {
            const copy = @min(512, data.len - offset);
            @memcpy(sector[0..copy], data[offset..][0..copy]);
        }

        var ok = false;
        for (0..3) |attempt| {
            if (write_one_sector(cur_lba, &sector)) {
                ok = true;
                break;
            }
            // Recovery: send TEST UNIT READY before retry
            if (attempt < 2) {
                _ = test_unit_ready();
            }
        }
        if (!ok) {
            owos.klog.warn("USB-MSC: WRITE failed lba={d} after retries", .{cur_lba});
            ready = false;
            return false;
        }

        offset += 512;
        remaining -= 1;
        cur_lba += 1;
    }
    return true;
}
