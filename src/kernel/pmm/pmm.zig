const limine = @import("limine");
const owos = @import("../root.zig");

pub export var memmap_request: limine.MemMapRequest linksection(".limine_requests") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};

pub var hhdm_offset: u64 = 0;

const PAGE_SIZE = 4096;
// Handles up to 16 GiB of physical memory (4M pages → 512 KiB bitmap in .bss)
const MAX_PAGES = 4 * 1024 * 1024;

var bitmap: [MAX_PAGES / 8]u8 = undefined;
var page_base: u64 = 0;
var page_count: usize = 0;
var alloc_cursor: usize = 0;

pub fn phys_to_virt(phys: u64) u64 {
    return hhdm_offset + phys;
}

pub fn init(memmap: *const limine.MemMapResponse, hhdm: *const limine.HhdmResponse) void {
    hhdm_offset = hhdm.offset;
    owos.klog.info("PMM: HHDM offset={x:0>16}", .{hhdm_offset});

    // Find the bounds of usable physical memory
    var lo: u64 = ~@as(u64, 0);
    var hi: u64 = 0;
    for (memmap.entries[0..memmap.entry_count]) |entry| {
        if (entry.type == .usable) {
            if (entry.base < lo) lo = entry.base;
            if (entry.base + entry.length > hi) hi = entry.base + entry.length;
        }
    }
    if (lo == ~@as(u64, 0)) {
        owos.klog.err("PMM: no usable memory!", .{});
        return;
    }

    page_base = lo & ~@as(u64, PAGE_SIZE - 1);
    page_count = @min((hi - page_base) / PAGE_SIZE, MAX_PAGES);

    // Start with all pages marked used, then free the usable ones
    @memset(&bitmap, 0xFF);
    var free_pages: usize = 0;
    for (memmap.entries[0..memmap.entry_count]) |entry| {
        if (entry.type != .usable) continue;
        const start = (entry.base - page_base) / PAGE_SIZE;
        const count = entry.length / PAGE_SIZE;
        for (start..start + count) |p| {
            if (p >= MAX_PAGES) break;
            bitmap[p / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(p % 8)));
            free_pages += 1;
        }
    }

    owos.klog.info("PMM: {d} free pages  ({d} MiB usable)", .{ free_pages, free_pages * PAGE_SIZE / 1024 / 1024 });
}

/// Allocates one zeroed 4 KiB physical page. Returns its physical address, or null if OOM.
pub fn alloc() ?u64 {
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const p = (alloc_cursor + i) % page_count;
        const bit: u8 = @as(u8, 1) << @as(u3, @truncate(p % 8));
        if (bitmap[p / 8] & bit == 0) {
            bitmap[p / 8] |= bit;
            alloc_cursor = (p + 1) % page_count;
            const phys = page_base + @as(u64, p) * PAGE_SIZE;
            const virt: [*]u8 = @ptrFromInt(phys_to_virt(phys));
            @memset(virt[0..PAGE_SIZE], 0);
            return phys;
        }
    }
    return null;
}

pub fn free(phys: u64) void {
    if (phys < page_base) return;
    const p = (phys - page_base) / PAGE_SIZE;
    if (p >= page_count) return;
    bitmap[p / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(p % 8)));
}
