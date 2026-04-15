const std = @import("std");
const owos = @import("../root.zig");
const limine = @import("limine");

pub export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};

var pm1a_cnt_blk: u16 = 0;
var slp_typa: u16 = 0;
var acpi_ready: bool = false;

// RSDP offsets
const RSDP_SIG = 0; // [8]u8
const RSDP_REVISION = 15; // u8
const RSDP_RSDT = 16; // u32
const RSDP_XSDT = 24; // u64
const RSDP_SIZE = 36;

// SDT header offsets
const SDT_SIG = 0; // [4]u8
const SDT_LEN = 4; // u32
const SDT_HDR_SIZE = 36;

// FADT offsets (from start of table)
const FADT_DSDT = SDT_HDR_SIZE + 4; // u32 (after firmware_ctrl)
const FADT_PM1A_CNT_BLK = SDT_HDR_SIZE + 32; // u32

fn phys_to_virt(phys: u64) u64 {
    return owos.pmm.hhdm_offset + phys;
}

fn ensure_mapped(phys: u64, len: u64) void {
    const page_mask: u64 = ~@as(u64, 0xFFF);
    var addr = phys & page_mask;
    const end = (phys + len + 0xFFF) & page_mask;
    while (addr < end) : (addr += 4096) {
        const virt = phys_to_virt(addr);
        if (!owos.vmm.is_mapped(virt)) {
            owos.vmm.map_page(virt, addr, owos.vmm.Flags.NX);
        }
    }
}

fn rd32(base: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, base[off..][0..4], .little);
}

fn rd64(base: [*]const u8, off: usize) u64 {
    return std.mem.readInt(u64, base[off..][0..8], .little);
}

fn sdt_len(base: [*]const u8) u32 {
    return rd32(base, SDT_LEN);
}

fn sdt_sig_match(base: [*]const u8, sig: *const [4]u8) bool {
    return base[SDT_SIG] == sig[0] and base[SDT_SIG + 1] == sig[1] and
        base[SDT_SIG + 2] == sig[2] and base[SDT_SIG + 3] == sig[3];
}

fn find_table_32(sdt: [*]const u8, sig: *const [4]u8) ?[*]const u8 {
    const len = sdt_len(sdt);
    const entries_bytes = len - SDT_HDR_SIZE;
    const entry_count = entries_bytes / 4;

    for (0..entry_count) |i| {
        const table_phys: u64 = rd32(sdt, SDT_HDR_SIZE + i * 4);
        ensure_mapped(table_phys, SDT_HDR_SIZE);
        const table: [*]const u8 = @ptrFromInt(phys_to_virt(table_phys));
        if (sdt_sig_match(table, sig)) {
            ensure_mapped(table_phys, sdt_len(table));
            return table;
        }
    }
    return null;
}

fn find_table_64(sdt: [*]const u8, sig: *const [4]u8) ?[*]const u8 {
    const len = sdt_len(sdt);
    const entries_bytes = len - SDT_HDR_SIZE;
    const entry_count = entries_bytes / 8;

    for (0..entry_count) |i| {
        const table_phys = rd64(sdt, SDT_HDR_SIZE + i * 8);
        ensure_mapped(table_phys, SDT_HDR_SIZE);
        const table: [*]const u8 = @ptrFromInt(phys_to_virt(table_phys));
        if (sdt_sig_match(table, sig)) {
            ensure_mapped(table_phys, sdt_len(table));
            return table;
        }
    }
    return null;
}

/// Scan the DSDT AML for the \_S5 sleep type value.
fn find_s5_slp_typ(dsdt: [*]const u8) ?u16 {
    const len = sdt_len(dsdt);

    var i: usize = SDT_HDR_SIZE;
    while (i + 8 < len) : (i += 1) {
        if (dsdt[i] == '_' and dsdt[i + 1] == 'S' and dsdt[i + 2] == '5' and dsdt[i + 3] == '_') {
            var j = i + 4;
            while (j < len and dsdt[j] != 0x12) : (j += 1) {
                if (j - i > 16) break;
            }
            if (j >= len or dsdt[j] != 0x12) {
                i = j;
                continue;
            }
            j += 1; // skip package op

            // Skip PkgLength (1-4 bytes)
            const pkg_lead = dsdt[j];
            j += 1 + @as(usize, @intCast(pkg_lead >> 6));

            // Skip NumElements
            j += 1;

            // SLP_TYPa: BytePrefix (0x0A) + byte, or raw byte
            if (dsdt[j] == 0x0A) j += 1;
            return @as(u16, dsdt[j]);
        }
    }
    return null;
}

pub fn init() void {
    const resp_ptr: *const volatile ?*limine.RsdpResponse = @ptrCast(&rsdp_request.response);
    const resp = resp_ptr.* orelse {
        owos.klog.err("ACPI: no RSDP from bootloader", .{});
        return;
    };

    ensure_mapped(resp.address, RSDP_SIZE);
    const rsdp: [*]const u8 = @ptrFromInt(phys_to_virt(resp.address));

    // Verify signature "RSD PTR "
    const expected = "RSD PTR ";
    var sig_ok = true;
    for (0..8) |k| {
        if (rsdp[RSDP_SIG + k] != expected[k]) sig_ok = false;
    }
    if (!sig_ok) {
        owos.klog.err("ACPI: invalid RSDP signature", .{});
        return;
    }

    const revision = rsdp[RSDP_REVISION];
    const xsdt_addr = rd64(rsdp, RSDP_XSDT);

    // Find FADT via XSDT (ACPI 2.0+) or RSDT
    const fadt: ?[*]const u8 = if (revision >= 2 and xsdt_addr != 0) blk: {
        ensure_mapped(xsdt_addr, SDT_HDR_SIZE);
        const xsdt: [*]const u8 = @ptrFromInt(phys_to_virt(xsdt_addr));
        ensure_mapped(xsdt_addr, sdt_len(xsdt));
        break :blk find_table_64(xsdt, "FACP");
    } else blk: {
        const rsdt_addr: u64 = rd32(rsdp, RSDP_RSDT);
        ensure_mapped(rsdt_addr, SDT_HDR_SIZE);
        const rsdt: [*]const u8 = @ptrFromInt(phys_to_virt(rsdt_addr));
        ensure_mapped(rsdt_addr, sdt_len(rsdt));
        break :blk find_table_32(rsdt, "FACP");
    };

    const fadt_ptr = fadt orelse {
        owos.klog.err("ACPI: FADT not found", .{});
        return;
    };

    pm1a_cnt_blk = @truncate(rd32(fadt_ptr, FADT_PM1A_CNT_BLK));

    // Parse DSDT for S5 sleep type
    const dsdt_phys: u64 = rd32(fadt_ptr, FADT_DSDT);
    ensure_mapped(dsdt_phys, SDT_HDR_SIZE);
    const dsdt: [*]const u8 = @ptrFromInt(phys_to_virt(dsdt_phys));
    ensure_mapped(dsdt_phys, sdt_len(dsdt));

    if (find_s5_slp_typ(dsdt)) |typ| {
        slp_typa = typ;
    } else {
        owos.klog.err("ACPI: \\_S5 sleep type not found in DSDT", .{});
        return;
    }

    acpi_ready = true;
    owos.klog.info("ACPI: PM1a_CNT=0x{X:0>4}  SLP_TYPa=0x{X:0>4}", .{ pm1a_cnt_blk, slp_typa });
}

fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn wipe_keys() void {
    @memset(&owos.ramfs.master_key, 0);
    // Wipe all per-file keys
    for (owos.ramfs.get_files()) |*slot| {
        if (slot.*) |*f| f.delete();
    }
}

pub fn shutdown() void {
    wipe_keys();
    if (acpi_ready) {
        const val: u16 = (slp_typa << 10) | (1 << 13);
        outw(pm1a_cnt_blk, val);
    }
    // QEMU/Bochs fallbacks
    outw(0x604, 0x2000);
    outb(0xB004, 0x00);
}

pub fn reboot() void {
    wipe_keys();
    outb(0x64, 0xFE);
}
