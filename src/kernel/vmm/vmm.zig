const owos = @import("../root.zig");
const pmm = @import("../pmm/pmm.zig");

pub const Flags = struct {
    pub const WRITE: u64 = 1 << 1;
    pub const NX: u64    = 1 << 63;
    // PRESENT is always set by map_page; no need to pass it in flags
};

const PRESENT: u64 = 1 << 0;
const ADDR_MASK: u64 = ~@as(u64, 0xFFF);

var pml4_phys: u64 = 0;

pub fn init() void {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[v]" : [v] "=r" (cr3));
    pml4_phys = cr3 & ADDR_MASK;
    owos.klog.info("VMM: PML4 phys={x:0>16}", .{pml4_phys});
}

fn entry_ptr(table_phys: u64, idx: usize) *volatile u64 {
    const table: [*]volatile u64 = @ptrFromInt(pmm.phys_to_virt(table_phys));
    return &table[idx];
}

/// Returns the physical address of the next-level table, allocating it if absent.
fn descend(table_phys: u64, idx: usize) u64 {
    const e = entry_ptr(table_phys, idx);
    if (e.* & PRESENT != 0) return e.* & ADDR_MASK;
    const child = pmm.alloc() orelse @panic("VMM: out of memory allocating page table");
    e.* = child | PRESENT | Flags.WRITE;
    return child;
}

pub fn map_page(virt: u64, phys: u64, flags: u64) void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx   = (virt >> 21) & 0x1FF;
    const pt_idx   = (virt >> 12) & 0x1FF;

    const pdpt_phys = descend(pml4_phys, pml4_idx);
    const pd_phys   = descend(pdpt_phys, pdpt_idx);
    const pt_phys   = descend(pd_phys,   pd_idx);

    entry_ptr(pt_phys, pt_idx).* = phys | PRESENT | flags;
}

/// Maps [virt_base, virt_base+size) to freshly allocated physical pages.
/// Stops early and logs a message if physical memory is exhausted.
pub fn map_range(virt_base: u64, size: u64, flags: u64) void {
    var offset: u64 = 0;
    var mapped: usize = 0;
    while (offset < size) : (offset += 4096) {
        const phys = pmm.alloc() orelse {
            owos.klog.warn("VMM: OOM after mapping {d} pages ({d} MiB)", .{ mapped, mapped * 4096 / 1024 / 1024 });
            return;
        };
        map_page(virt_base + offset, phys, flags);
        mapped += 1;
    }
    owos.klog.info("VMM: mapped {d} pages  ({d} MiB)", .{ mapped, mapped * 4096 / 1024 / 1024 });
}
