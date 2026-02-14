const std = @import("std");
const owos = @import("../root.zig");

extern var hhdm_request: owos.c.struct_limine_hhdm_request;
extern var memmap_request: owos.c.struct_limine_memmap_request;

pub const RawStorage = struct {
    data: [*]u8,
    len: usize,

    pub fn init() RawStorage {
        var shell = owos.std.get_process_as(owos.shell.Shell, 0).?;
        const hhdm_resp = hhdm_request.response orelse @panic("No HHDM response");
        const hhdm_offset = hhdm_resp.*.offset;
 
        const memmap_resp = memmap_request.response orelse @panic("No memmap response");

        var best_entry: ?*owos.c.struct_limine_memmap_entry = null;
        var best_size: u64 = 0;

        var i: u64 = 0;
        while (i < memmap_resp.*.entry_count) : (i += 1) {
            const entry = memmap_resp.*.entries[i];
            if (entry.*.type == owos.c.LIMINE_MEMMAP_USABLE and entry.*.length > best_size) {
                best_size = entry.*.length;
                best_entry = entry;
            }
        }

        if (best_entry == null or best_size < 64 * 1024 * 1024) {
            shell.println("Not enough RAM for ramfs", 0xFF7777, false, &owos.c.OwOSFont_8x16);
            @panic("Not enough RAM for ramfs");
        }

        const desired_size: u64 = 1024 * 1024 * 1024;
        const actual_size: usize = @min(best_size, desired_size);

        const phys_base = best_entry.?.base;
        const virt_base = phys_base + hhdm_offset;

        const bytes: []u8 = @as([*]u8, @ptrFromInt(virt_base))[0..actual_size];

        shell.print("[OWOS MEM] -> ", 0x7777FF, false, &owos.c.OwOSFont_8x16);
        shell.println("Initializing virtual storage...", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        _ = owos.c.owos_memset(@ptrCast(bytes.ptr), 0, bytes.len);
        shell.print("[OWOS MEM] -> ", 0x7777FF, false, &owos.c.OwOSFont_8x16);
        shell.print("Allocated ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        var buf = [_:0]u8{0} ** 32;
        owos.c.format(@ptrCast(&buf), "%dMB of virtual storage (%dB)", bytes.len / (1024 * 1024), bytes.len);
        shell.println(&buf, 0xAAAAAA, false, &owos.c.OwOSFont_8x16);

        return .{ .data = bytes.ptr, .len = bytes.len };
    }

    pub fn store(self: *RawStorage, src: []const u8, dest: usize) void {
        std.debug.assert(dest + src.len <= self.len);
        owos.c.owos_memcpy(self.data[dest .. dest + src.len], src, src.len);
    }

    pub fn store_safe(self: *RawStorage, src: []const u8, dest: usize) !void {
        if (dest + src.len > self.len) {
            return error.OutOfBounds;
        }

        for (self.data[dest .. dest + src.len]) |byte| {
            if (byte != 0) {
                return error.RegionNotFree;
            }
        }

        self.store(src, dest);
    }
};


pub const File = struct {
    name: *[]const u8,
    start: u32,
    end: u32,
    data: []u8
};
