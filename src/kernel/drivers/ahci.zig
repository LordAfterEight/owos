const std = @import("std");
const owos = @import("../root.zig");
const pci = owos.pci;
const pmm = owos.pmm;
const vmm = owos.vmm;

// HBA global register offsets
const HBA_CAP = 0x00;
const HBA_GHC = 0x04;
const HBA_IS = 0x08;
const HBA_PI = 0x0C;

// Port register offsets (base = 0x100 + port * 0x80)
const PORT_CLB = 0x00;
const PORT_CLBU = 0x04;
const PORT_FB = 0x08;
const PORT_FBU = 0x0C;
const PORT_IS = 0x10;
const PORT_CMD = 0x18;
const PORT_TFD = 0x20;
const PORT_SIG = 0x24;
const PORT_SSTS = 0x28;
const PORT_SERR = 0x30;
const PORT_CI = 0x38;

// PORT_CMD bits
const CMD_ST = 1 << 0;
const CMD_FRE = 1 << 4;
const CMD_FR = 1 << 14;
const CMD_CR = 1 << 15;

// FIS types
const FIS_REG_H2D: u8 = 0x27;

// ATA commands
const ATA_READ_DMA_EX: u8 = 0x25;
const ATA_WRITE_DMA_EX: u8 = 0x35;

var mmio_base: u64 = 0;
pub var ready: bool = false;
var active_port: u32 = 0;

// DMA regions (physical addresses)
var clb_phys: u64 = 0; // Command List Base
var fb_phys: u64 = 0; // FIS Base
var ctbl_phys: u64 = 0; // Command Table
var dma_phys: u64 = 0; // Read buffer

// DMA regions (virtual addresses)
var clb_virt: u64 = 0;
var fb_virt: u64 = 0;
var ctbl_virt: u64 = 0;
var dma_virt: u64 = 0;

fn hba_read(off: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + off);
    return ptr.*;
}

fn hba_write(off: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + off);
    ptr.* = val;
}

fn port_read(port: u32, off: u32) u32 {
    return hba_read(0x100 + port * 0x80 + off);
}

fn port_write(port: u32, off: u32, val: u32) void {
    hba_write(0x100 + port * 0x80 + off, val);
}

fn map_mmio(phys: u64, size: u64) void {
    const page_mask: u64 = ~@as(u64, 0xFFF);
    var addr = phys & page_mask;
    const end = (phys + size + 0xFFF) & page_mask;
    while (addr < end) : (addr += 4096) {
        const virt = pmm.phys_to_virt(addr);
        if (!vmm.is_mapped(virt)) {
            vmm.map_page(virt, addr, vmm.Flags.WRITE | vmm.Flags.NX);
        }
    }
}

fn stop_port(port: u32) void {
    var cmd = port_read(port, PORT_CMD);
    cmd &= ~@as(u32, CMD_ST);
    port_write(port, PORT_CMD, cmd);
    var t: u32 = 0;
    while (port_read(port, PORT_CMD) & CMD_CR != 0) {
        t += 1;
        if (t > 1_000_000) break;
    }
    cmd = port_read(port, PORT_CMD);
    cmd &= ~@as(u32, CMD_FRE);
    port_write(port, PORT_CMD, cmd);
    t = 0;
    while (port_read(port, PORT_CMD) & CMD_FR != 0) {
        t += 1;
        if (t > 1_000_000) break;
    }
}

fn start_port(port: u32) void {
    var t: u32 = 0;
    while (port_read(port, PORT_CMD) & CMD_CR != 0) {
        t += 1;
        if (t > 1_000_000) break;
    }
    var cmd = port_read(port, PORT_CMD);
    cmd |= CMD_FRE;
    port_write(port, PORT_CMD, cmd);
    cmd = port_read(port, PORT_CMD);
    cmd |= CMD_ST;
    port_write(port, PORT_CMD, cmd);
}

fn alloc_dma() bool {
    clb_phys = pmm.alloc() orelse return false;
    fb_phys = pmm.alloc() orelse return false;
    ctbl_phys = pmm.alloc() orelse return false;
    dma_phys = pmm.alloc() orelse return false;
    clb_virt = pmm.phys_to_virt(clb_phys);
    fb_virt = pmm.phys_to_virt(fb_phys);
    ctbl_virt = pmm.phys_to_virt(ctbl_phys);
    dma_virt = pmm.phys_to_virt(dma_phys);
    return true;
}

fn setup_port(port: u32) void {
    stop_port(port);

    // Clear errors
    port_write(port, PORT_SERR, 0xFFFFFFFF);
    port_write(port, PORT_IS, 0xFFFFFFFF);

    // Set command list and FIS base addresses
    port_write(port, PORT_CLB, @truncate(clb_phys));
    port_write(port, PORT_CLBU, @truncate(clb_phys >> 32));
    port_write(port, PORT_FB, @truncate(fb_phys));
    port_write(port, PORT_FBU, @truncate(fb_phys >> 32));

    start_port(port);
}

fn read_dma(lba: u64, count: u16) bool {
    const port = active_port;

    // Clear interrupts
    port_write(port, PORT_IS, port_read(port, PORT_IS));

    // Wait for port not busy
    var t: u32 = 0;
    while (port_read(port, PORT_TFD) & 0x88 != 0) { // BSY | DRQ
        t += 1;
        if (t > 1_000_000) return false;
    }

    // -- Command header (slot 0, 32 bytes at CLB) --
    const hdr: [*]volatile u32 = @ptrFromInt(clb_virt);
    hdr[0] = 5 | (1 << 16); // CFL=5 dwords, PRDTL=1
    hdr[1] = 0;
    hdr[2] = @truncate(ctbl_phys);
    hdr[3] = @truncate(ctbl_phys >> 32);
    hdr[4] = 0;
    hdr[5] = 0;
    hdr[6] = 0;
    hdr[7] = 0;

    // -- Command table: clear header area --
    const ct: [*]volatile u8 = @ptrFromInt(ctbl_virt);
    for (0..128) |i| ct[i] = 0;

    // -- H2D Register FIS (20 bytes at command table offset 0) --
    ct[0] = FIS_REG_H2D;
    ct[1] = 0x80; // C=1 (command)
    ct[2] = ATA_READ_DMA_EX;
    ct[3] = 0; // Features
    ct[4] = @truncate(lba);
    ct[5] = @truncate(lba >> 8);
    ct[6] = @truncate(lba >> 16);
    ct[7] = 0x40; // LBA mode
    ct[8] = @truncate(lba >> 24);
    ct[9] = @truncate(lba >> 32);
    ct[10] = @truncate(lba >> 40);
    ct[11] = 0;
    ct[12] = @truncate(count);
    ct[13] = @truncate(count >> 8);

    // -- PRDT entry (16 bytes at command table offset 0x80) --
    const prdt: [*]volatile u32 = @ptrFromInt(ctbl_virt + 0x80);
    prdt[0] = @truncate(dma_phys);
    prdt[1] = @truncate(dma_phys >> 32);
    prdt[2] = 0;
    prdt[3] = @as(u32, count) * 512 - 1; // byte count minus 1

    // -- Issue command --
    port_write(port, PORT_CI, 1);

    // -- Wait for completion --
    t = 0;
    while (true) {
        if (port_read(port, PORT_CI) & 1 == 0) break;
        if (port_read(port, PORT_IS) & (1 << 30) != 0) return false; // TFES
        t += 1;
        if (t > 10_000_000) return false;
    }

    return true;
}

pub fn init() void {
    // Find AHCI controller: PCI class 01h (mass storage), subclass 06h (SATA)
    const dev = pci.find_by_class(0x01, 0x06) orelse {
        owos.klog.warn("AHCI: no SATA controller found on PCI bus", .{});
        return;
    };

    // AHCI uses BAR5 (ABAR)
    const bar5 = pci.config_read32(dev.bus, dev.slot, dev.func, 0x24);
    const abar: u64 = bar5 & 0xFFFFFFF0;
    if (abar == 0) {
        owos.klog.err("AHCI: BAR5 is zero", .{});
        return;
    }

    map_mmio(abar, 0x2000);
    mmio_base = pmm.phys_to_virt(abar);

    // Enable AHCI mode
    hba_write(HBA_GHC, hba_read(HBA_GHC) | (1 << 31));

    // Allocate DMA memory
    if (!alloc_dma()) {
        owos.klog.err("AHCI: out of memory for DMA buffers", .{});
        return;
    }

    // Scan ports for devices
    const pi = hba_read(HBA_PI);
    var found = false;
    for (0..32) |p| {
        const port: u32 = @truncate(p);
        if (pi & (@as(u32, 1) << @truncate(port)) == 0) continue;

        const ssts = port_read(port, PORT_SSTS);
        const det = ssts & 0x0F;
        if (det != 3) continue; // No device or no communication

        const sig = port_read(port, PORT_SIG);
        if (sig != 0x00000101) continue; // Not a SATA drive (skip ATAPI etc.)

        setup_port(port);
        active_port = port;
        found = true;
        owos.klog.info("AHCI: SATA drive on port {d}", .{port});
        break;
    }

    if (!found) {
        owos.klog.warn("AHCI: no SATA drives detected", .{});
        return;
    }

    ready = true;
    owos.klog.info("AHCI: ready  ABAR={x:0>8}  port={d}", .{ abar, active_port });
}

/// Read sectors from the active device. Copies data into `out`.
/// Returns true on success.
fn write_dma(lba: u64, count: u16) bool {
    const port = active_port;

    port_write(port, PORT_IS, port_read(port, PORT_IS));

    var t: u32 = 0;
    while (port_read(port, PORT_TFD) & 0x88 != 0) {
        t += 1;
        if (t > 1_000_000) return false;
    }

    const hdr: [*]volatile u32 = @ptrFromInt(clb_virt);
    hdr[0] = 5 | (1 << 6) | (1 << 16); // CFL=5, W=1, PRDTL=1
    hdr[1] = 0;
    hdr[2] = @truncate(ctbl_phys);
    hdr[3] = @truncate(ctbl_phys >> 32);
    hdr[4] = 0;
    hdr[5] = 0;
    hdr[6] = 0;
    hdr[7] = 0;

    const ct: [*]volatile u8 = @ptrFromInt(ctbl_virt);
    for (0..128) |i| ct[i] = 0;

    ct[0] = FIS_REG_H2D;
    ct[1] = 0x80;
    ct[2] = ATA_WRITE_DMA_EX;
    ct[3] = 0;
    ct[4] = @truncate(lba);
    ct[5] = @truncate(lba >> 8);
    ct[6] = @truncate(lba >> 16);
    ct[7] = 0x40;
    ct[8] = @truncate(lba >> 24);
    ct[9] = @truncate(lba >> 32);
    ct[10] = @truncate(lba >> 40);
    ct[11] = 0;
    ct[12] = @truncate(count);
    ct[13] = @truncate(count >> 8);

    const prdt: [*]volatile u32 = @ptrFromInt(ctbl_virt + 0x80);
    prdt[0] = @truncate(dma_phys);
    prdt[1] = @truncate(dma_phys >> 32);
    prdt[2] = 0;
    prdt[3] = @as(u32, count) * 512 - 1;

    port_write(port, PORT_CI, 1);

    t = 0;
    while (true) {
        if (port_read(port, PORT_CI) & 1 == 0) break;
        if (port_read(port, PORT_IS) & (1 << 30) != 0) return false;
        t += 1;
        if (t > 10_000_000) return false;
    }

    return true;
}

/// Write sectors to the active device from `data`.
pub fn write_sectors(lba: u64, count: u32, data: []const u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;
    while (remaining > 0) {
        const chunk: u16 = @intCast(@min(remaining, 8));
        const bytes: usize = @as(usize, chunk) * 512;
        const copy = @min(bytes, data.len - offset);
        const dst: [*]u8 = @ptrFromInt(dma_virt);
        @memcpy(dst[0..copy], data[offset..][0..copy]);
        if (copy < bytes) {
            const pad: [*]u8 = @ptrFromInt(dma_virt + copy);
            @memset(pad[0 .. bytes - copy], 0);
        }
        if (!write_dma(cur_lba, chunk)) return false;
        offset += bytes;
        remaining -= chunk;
        cur_lba += chunk;
    }
    return true;
}

/// Read sectors from the active device. Copies data into `out`.
/// Returns true on success.
pub fn read_sectors(lba: u64, count: u32, out: []u8) bool {
    if (!ready or count == 0) return false;
    var remaining: u32 = count;
    var cur_lba = lba;
    var offset: usize = 0;
    while (remaining > 0) {
        const chunk: u16 = @intCast(@min(remaining, 8)); // Max 8 sectors (4K) per DMA
        if (!read_dma(cur_lba, chunk)) return false;
        const bytes: usize = @as(usize, chunk) * 512;
        const copy = @min(bytes, out.len - offset);
        const src: [*]const u8 = @ptrFromInt(dma_virt);
        @memcpy(out[offset..][0..copy], src[0..copy]);
        offset += copy;
        remaining -= chunk;
        cur_lba += chunk;
    }
    return true;
}
