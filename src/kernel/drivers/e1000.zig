const owos = @import("../root.zig");
const pci = owos.pci;
const pmm = owos.pmm;
const vmm = owos.vmm;

// E1000 register offsets
const REG_CTRL = 0x0000;
const REG_STATUS = 0x0008;
const REG_EERD = 0x0014;
const REG_ICR = 0x00C0;
const REG_IMS = 0x00D0;
const REG_IMC = 0x00D8;
const REG_RCTL = 0x0100;
const REG_TCTL = 0x0400;
const REG_RDBAL = 0x2800;
const REG_RDBAH = 0x2804;
const REG_RDLEN = 0x2808;
const REG_RDH = 0x2810;
const REG_RDT = 0x2818;
const REG_TDBAL = 0x3800;
const REG_TDBAH = 0x3804;
const REG_TDLEN = 0x3808;
const REG_TDH = 0x3810;
const REG_TDT = 0x3818;
const REG_RAL = 0x5400;
const REG_RAH = 0x5404;
const REG_MTA = 0x5200;

// CTRL bits
const CTRL_SLU = 1 << 6;
const CTRL_RST = 1 << 26;

// RCTL bits
const RCTL_EN = 1 << 1;
const RCTL_UPE = 1 << 3;
const RCTL_MPE = 1 << 4;
const RCTL_BAM = 1 << 15;
const RCTL_SECRC = 1 << 26;

// TCTL bits
const TCTL_EN = 1 << 1;
const TCTL_PSP = 1 << 3;

// TX command bits
const TX_CMD_EOP = 1 << 0;
const TX_CMD_IFCS = 1 << 1;
const TX_CMD_RS = 1 << 3;

const NUM_RX_DESC = 32;
const NUM_TX_DESC = 8;

const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

var mmio_base: u64 = 0;
pub var mac: [6]u8 = undefined;
pub var ready: bool = false;

// Descriptor ring state
var rx_descs: [*]volatile RxDesc = undefined;
var tx_descs: [*]volatile TxDesc = undefined;
var rx_descs_phys: u64 = 0;
var tx_descs_phys: u64 = 0;
var rx_bufs_phys: [NUM_RX_DESC]u64 = undefined;
var rx_bufs_virt: [NUM_RX_DESC][*]u8 = undefined;
var tx_buf_phys: u64 = 0;
var tx_buf_virt: [*]u8 = undefined;
var rx_cur: u32 = 0;
var tx_cur: u32 = 0;

fn mmio_read(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    return ptr.*;
}

fn mmio_write(offset: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + offset);
    ptr.* = value;
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

fn read_mac_addr() void {
    const ral = mmio_read(REG_RAL);
    const rah = mmio_read(REG_RAH);
    mac[0] = @truncate(ral);
    mac[1] = @truncate(ral >> 8);
    mac[2] = @truncate(ral >> 16);
    mac[3] = @truncate(ral >> 24);
    mac[4] = @truncate(rah);
    mac[5] = @truncate(rah >> 8);
}

fn init_rx() void {
    rx_descs_phys = pmm.alloc() orelse @panic("E1000: OOM for RX descriptor ring");
    rx_descs = @ptrFromInt(pmm.phys_to_virt(rx_descs_phys));

    for (0..NUM_RX_DESC) |i| {
        rx_bufs_phys[i] = pmm.alloc() orelse @panic("E1000: OOM for RX buffer");
        rx_bufs_virt[i] = @ptrFromInt(pmm.phys_to_virt(rx_bufs_phys[i]));
        rx_descs[i] = .{
            .addr = rx_bufs_phys[i],
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }

    mmio_write(REG_RDBAL, @truncate(rx_descs_phys));
    mmio_write(REG_RDBAH, @truncate(rx_descs_phys >> 32));
    mmio_write(REG_RDLEN, NUM_RX_DESC * @sizeOf(RxDesc));
    mmio_write(REG_RDH, 0);
    mmio_write(REG_RDT, NUM_RX_DESC - 1);
    mmio_write(REG_RCTL, RCTL_EN | RCTL_BAM | RCTL_UPE | RCTL_MPE | RCTL_SECRC);
}

fn init_tx() void {
    tx_descs_phys = pmm.alloc() orelse @panic("E1000: OOM for TX descriptor ring");
    tx_descs = @ptrFromInt(pmm.phys_to_virt(tx_descs_phys));

    tx_buf_phys = pmm.alloc() orelse @panic("E1000: OOM for TX buffer");
    tx_buf_virt = @ptrFromInt(pmm.phys_to_virt(tx_buf_phys));

    for (0..NUM_TX_DESC) |i| {
        tx_descs[i] = .{
            .addr = 0,
            .length = 0,
            .cso = 0,
            .cmd = 0,
            .status = 0,
            .css = 0,
            .special = 0,
        };
    }

    mmio_write(REG_TDBAL, @truncate(tx_descs_phys));
    mmio_write(REG_TDBAH, @truncate(tx_descs_phys >> 32));
    mmio_write(REG_TDLEN, NUM_TX_DESC * @sizeOf(TxDesc));
    mmio_write(REG_TDH, 0);
    mmio_write(REG_TDT, 0);
    // EN + PSP + CT=15 + COLD=64 (full duplex)
    mmio_write(REG_TCTL, TCTL_EN | TCTL_PSP | (15 << 4) | (64 << 12));
}

pub fn init() void {
    const dev = pci.find_device(0x8086, 0x100E) orelse {
        owos.klog.err("E1000: device not found on PCI bus (8086:100E)", .{});
        return;
    };

    map_mmio(dev.bar0, 0x20000);
    mmio_base = pmm.phys_to_virt(dev.bar0);

    // Reset device
    var ctrl = mmio_read(REG_CTRL);
    mmio_write(REG_CTRL, ctrl | CTRL_RST);
    for (0..100_000) |_| {
        if (mmio_read(REG_CTRL) & CTRL_RST == 0) break;
    }

    // Disable interrupts
    mmio_write(REG_IMC, 0xFFFFFFFF);
    _ = mmio_read(REG_ICR);

    // Read MAC from receive address registers
    read_mac_addr();

    // Clear multicast table
    for (0..128) |i| {
        mmio_write(REG_MTA + @as(u32, @truncate(i)) * 4, 0);
    }

    init_rx();
    init_tx();

    // Set link up
    ctrl = mmio_read(REG_CTRL);
    mmio_write(REG_CTRL, ctrl | CTRL_SLU);

    ready = true;
    owos.klog.info("E1000: ready  BAR0={x:0>8}  IRQ={d}", .{ dev.bar0, dev.irq });
    owos.klog.info("E1000: MAC={X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
}

/// Send a raw Ethernet frame. `data` is the complete frame including Ethernet header.
pub fn send(data: []const u8) void {
    if (!ready) return;
    const len: usize = @min(data.len, 4096);
    @memcpy(tx_buf_virt[0..len], data[0..len]);

    const i = tx_cur;
    tx_descs[i] = .{
        .addr = tx_buf_phys,
        .length = @intCast(len),
        .cso = 0,
        .cmd = TX_CMD_EOP | TX_CMD_IFCS | TX_CMD_RS,
        .status = 0,
        .css = 0,
        .special = 0,
    };
    tx_cur = (tx_cur + 1) % NUM_TX_DESC;
    mmio_write(REG_TDT, tx_cur);

    // Wait for transmit to complete
    var timeout: u32 = 0;
    while (tx_descs[i].status & 0x01 == 0) {
        timeout += 1;
        if (timeout > 1_000_000) return;
    }
}

/// Poll for a received Ethernet frame. Returns the frame data or null.
/// The returned slice is only valid until the next call to receive().
pub fn receive() ?[]u8 {
    if (!ready) return null;
    const desc = &rx_descs[rx_cur];
    if (desc.status & 0x01 == 0) return null; // DD bit not set

    const len = desc.length;
    const data = rx_bufs_virt[rx_cur][0..len];

    // Recycle descriptor
    desc.status = 0;
    const old = rx_cur;
    rx_cur = (rx_cur + 1) % NUM_RX_DESC;
    mmio_write(REG_RDT, old);

    return data;
}
