const std = @import("std");
const owos = @import("../root.zig");
const pci = owos.pci;
const pmm = owos.pmm;
const vmm = owos.vmm;

// ── TRB types ──────────────────────────────────────────────────────────

const TRB_NORMAL: u32 = 1;
const TRB_SETUP: u32 = 2;
const TRB_DATA: u32 = 3;
const TRB_STATUS: u32 = 4;
const TRB_LINK: u32 = 6;
const TRB_ENABLE_SLOT: u32 = 9;
const TRB_DISABLE_SLOT: u32 = 10;
const TRB_ADDRESS_DEV: u32 = 11;
const TRB_CONFIG_EP: u32 = 12;
const TRB_EVAL_CTX: u32 = 13;
const TRB_CMD_COMPLETE: u32 = 33;
const TRB_XFER_EVENT: u32 = 32;

const CC_SUCCESS: u8 = 1;
const CC_SHORT: u8 = 13;

const RING_N: u32 = 256;

// ── State ──────────────────────────────────────────────────────────────

pub var ready: bool = false;

var cap_base: u64 = 0;
var op_base: u64 = 0;
var rt_base: u64 = 0;
var db_base: u64 = 0;
var n_slots: u32 = 0;
var n_ports: u32 = 0;
var csz: u32 = 32;

const Ring = struct { phys: u64 = 0, virt: u64 = 0, i: u32 = 0, c: u1 = 1 };

var cr: Ring = .{};
var er: Ring = .{};
var ep0r: Ring = .{};
var bir: Ring = .{};
var bor: Ring = .{};

pub var sid: u8 = 0;
var spd: u32 = 0;
var prt: u32 = 0;
pub var bi_dci: u32 = 0;
pub var bo_dci: u32 = 0;

var dcbaa_p: u64 = 0;
var dcbaa_v: u64 = 0;
var ictx_p: u64 = 0;
var ictx_v: u64 = 0;
var dctx_p: u64 = 0;
var dctx_v: u64 = 0;
var dbuf_p: u64 = 0;
var dbuf_v: u64 = 0;

// ── MMIO ───────────────────────────────────────────────────────────────

fn r32(a: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}
fn w32(a: u64, v: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = v;
}
fn r64(a: u64) u64 {
    return @as(*volatile u64, @ptrFromInt(a)).*;
}
fn w64(a: u64, v: u64) void {
    // Many XHCI controllers require 32-bit MMIO writes for 64-bit registers
    w32(a, @truncate(v));
    w32(a + 4, @truncate(v >> 32));
}

fn psc_addr(p: u32) u64 {
    return op_base + 0x400 + (@as(u64, p) - 1) * 0x10;
}

// ── Memory ─────────────────────────────────────────────────────────────

const Pg = struct { p: u64, v: u64 };

fn zpage() ?Pg {
    const phys = pmm.alloc() orelse return null;
    const virt = pmm.phys_to_virt(phys);
    const ptr: [*]volatile u8 = @ptrFromInt(virt);
    for (0..4096) |i| ptr[i] = 0;
    return .{ .p = phys, .v = virt };
}

fn mmap(phys: u64, sz: u64) void {
    var a = phys & ~@as(u64, 0xFFF);
    const end = (phys + sz + 0xFFF) & ~@as(u64, 0xFFF);
    while (a < end) : (a += 4096) {
        const v = pmm.phys_to_virt(a);
        if (!vmm.is_mapped(v)) vmm.map_page(v, a, vmm.Flags.WRITE | vmm.Flags.NX);
    }
}

fn spin(n: u32) void {
    for (0..n) |_| asm volatile ("pause");
}

// ── Ring management ────────────────────────────────────────────────────

fn ring_new(ring: *Ring) bool {
    const pg = zpage() orelse return false;
    ring.* = .{ .phys = pg.p, .virt = pg.v, .i = 0, .c = 1 };
    // Link TRB at last slot → wraps to ring start, TC=1
    const off = ring.virt + (RING_N - 1) * 16;
    w32(off, @truncate(ring.phys));
    w32(off + 4, @truncate(ring.phys >> 32));
    w32(off + 8, 0);
    w32(off + 12, (TRB_LINK << 10) | (1 << 5)); // TC=1, cycle=0
    return true;
}

fn ring_put(ring: *Ring, lo: u64, st: u32, ct: u32) void {
    const off = ring.virt + @as(u64, ring.i) * 16;
    w32(off, @truncate(lo));
    w32(off + 4, @truncate(lo >> 32));
    w32(off + 8, st);
    w32(off + 12, (ct & ~@as(u32, 1)) | @as(u32, ring.c));
    ring.i += 1;
    if (ring.i >= RING_N - 1) {
        const la = ring.virt + (RING_N - 1) * 16 + 12;
        w32(la, (r32(la) & ~@as(u32, 1)) | @as(u32, ring.c));
        ring.i = 0;
        ring.c ^= 1;
    }
}

fn db_ring(s: u32, target: u32) void {
    w32(db_base + s * 4, target);
}

// ── Event ring ─────────────────────────────────────────────────────────

const Evt = struct { lo: u64, status: u32, ctrl: u32 };

fn poll_evt() ?Evt {
    // Clear EINT + PCD so controller can post new events
    const sts = r32(op_base + 4);
    if (sts & 0x18 != 0) w32(op_base + 4, sts & 0x18); // RW1C: write 1 to clear

    // Also clear IP on interrupter 0
    const ir0 = rt_base + 0x20;
    const iman = r32(ir0);
    if (iman & 1 != 0) w32(ir0, iman | 1); // write 1 to IP clears it

    const off = er.virt + @as(u64, er.i) * 16;
    const c = r32(off + 12);
    if (c & 1 != @as(u32, er.c)) return null;
    const e = Evt{
        .lo = @as(u64, r32(off)) | (@as(u64, r32(off + 4)) << 32),
        .status = r32(off + 8),
        .ctrl = c,
    };
    er.i += 1;
    if (er.i >= RING_N) {
        er.i = 0;
        er.c ^= 1;
    }
    // Update ERDP with EHB=1 to clear Event Handler Busy
    w64(rt_base + 0x38, er.phys + @as(u64, er.i) * 16 | 8);
    return e;
}

const CmdResult = struct { cc: u8, slot_id: u8 };

fn wait_cmd() ?CmdResult {
    return wait_cmd_n(10_000_000);
}

fn wait_cmd_n(n: u32) ?CmdResult {
    for (0..n) |_| {
        if (poll_evt()) |e| {
            if ((e.ctrl >> 10) & 0x3F == TRB_CMD_COMPLETE)
                return .{ .cc = @truncate(e.status >> 24), .slot_id = @truncate(e.ctrl >> 24) };
        }
    }
    return null;
}

fn abort_cmd() void {
    // Write CA (Command Abort) bit to CRCR to stop a stuck command
    w32(op_base + 0x18, r32(op_base + 0x18) | (1 << 2));
    // Wait for CRR (Command Ring Running) to clear
    for (0..1_000_000) |_| {
        if (r32(op_base + 0x18) & (1 << 3) == 0) break;
    }
    // Drain any completion events from the abort
    for (0..100) |_| {
        if (poll_evt() == null) break;
    }
}

fn wait_xfer() ?struct { cc: u8, rem: u32 } {
    for (0..10_000_000) |_| {
        if (poll_evt()) |e| {
            if ((e.ctrl >> 10) & 0x3F == TRB_XFER_EVENT)
                return .{ .cc = @truncate(e.status >> 24), .rem = e.status & 0xFFFFFF };
        }
    }
    return null;
}

// ── BIOS handoff ───────────────────────────────────────────────────────

fn bios_handoff() void {
    const hcc1 = r32(cap_base + 0x10);
    const ecp = (hcc1 >> 16) & 0xFFFF;
    if (ecp == 0) return;

    var off: u64 = @as(u64, ecp) << 2;
    while (off != 0) {
        const addr = cap_base + off;
        const cap = r32(addr);
        const id = cap & 0xFF;

        if (id == 1) { // USBLEGSUP
            if (cap & (1 << 16) != 0) { // BIOS owns controller
                w32(addr, cap | (1 << 24)); // request OS ownership
                for (0..10_000_000) |_| {
                    if (r32(addr) & (1 << 16) == 0) break;
                }
                // Disable legacy SMI interrupts
                w32(addr + 4, 0);
                owos.klog.info("XHCI: BIOS handoff complete", .{});
            }
            return;
        }

        const next = (cap >> 8) & 0xFF;
        if (next == 0) break;
        off += @as(u64, next) << 2;
    }
}

// ── Controller init ────────────────────────────────────────────────────

pub fn init() void {
    ready = false;

    // Find XHCI: class 0C (serial bus), subclass 03 (USB), prog IF 30 (XHCI)
    const dev = pci.find_by_class_progif(0x0C, 0x03, 0x30) orelse {
        owos.klog.warn("XHCI: no XHCI controller found", .{});
        return;
    };

    // Read BAR0 (may be 64-bit)
    const bar0 = pci.config_read32(dev.bus, dev.slot, dev.func, 0x10);
    var mmio: u64 = @as(u64, bar0) & 0xFFFFFFF0;
    if (bar0 & 0x04 != 0)
        mmio |= @as(u64, pci.config_read32(dev.bus, dev.slot, dev.func, 0x14)) << 32;
    if (mmio == 0) {
        owos.klog.err("XHCI: BAR0 is zero", .{});
        return;
    }

    mmap(mmio, 0x10000);
    cap_base = pmm.phys_to_virt(mmio);

    const caplen: u32 = r32(cap_base) & 0xFF;
    op_base = cap_base + caplen;

    const hcs1 = r32(cap_base + 0x04);
    n_slots = hcs1 & 0xFF;
    n_ports = (hcs1 >> 24) & 0xFF;

    const hcs2 = r32(cap_base + 0x08);
    const scratch_lo = (hcs2 >> 27) & 0x1F;
    const scratch_hi = (hcs2 >> 21) & 0x1F;
    const n_scratch = (scratch_hi << 5) | scratch_lo;

    const hcc1 = r32(cap_base + 0x10);
    csz = if (hcc1 & 4 != 0) 64 else 32;

    db_base = cap_base + (r32(cap_base + 0x14) & 0xFFFFFFFC);
    rt_base = cap_base + (r32(cap_base + 0x18) & 0xFFFFFFE0);

    owos.klog.info("XHCI: {d} slots, {d} ports, ctx={d}B, scratch={d}", .{ n_slots, n_ports, csz, n_scratch });

    // BIOS/OS handoff — claim ownership from firmware
    bios_handoff();

    // Stop
    w32(op_base, r32(op_base) & ~@as(u32, 1));
    for (0..1_000_000) |_| {
        if (r32(op_base + 4) & 1 != 0) break;
    }

    // Reset
    w32(op_base, 1 << 1);
    for (0..1_000_000) |_| {
        if (r32(op_base) & 2 == 0) break;
    }
    for (0..1_000_000) |_| {
        if (r32(op_base + 4) & (1 << 11) == 0) break;
    }

    w32(op_base + 0x38, n_slots);

    // DCBAA
    const da = zpage() orelse {
        owos.klog.err("XHCI: OOM", .{});
        return;
    };
    dcbaa_p = da.p;
    dcbaa_v = da.v;
    w64(op_base + 0x30, dcbaa_p);

    // Scratchpad
    if (n_scratch > 0) {
        const arr = zpage() orelse {
            owos.klog.err("XHCI: OOM scratch", .{});
            return;
        };
        const sp: [*]volatile u64 = @ptrFromInt(arr.v);
        for (0..n_scratch) |i| {
            const bp = pmm.alloc() orelse {
                owos.klog.err("XHCI: OOM scratch buf", .{});
                return;
            };
            const bv: [*]volatile u8 = @ptrFromInt(pmm.phys_to_virt(bp));
            for (0..4096) |j| bv[j] = 0;
            sp[i] = bp;
        }
        @as(*volatile u64, @ptrFromInt(dcbaa_v)).* = arr.p;
    }

    // Command ring
    if (!ring_new(&cr)) {
        owos.klog.err("XHCI: OOM cr", .{});
        return;
    }
    w64(op_base + 0x18, cr.phys | 1);

    // Event ring
    const ep = zpage() orelse {
        owos.klog.err("XHCI: OOM er", .{});
        return;
    };
    er = .{ .phys = ep.p, .virt = ep.v, .i = 0, .c = 1 };

    // ERST (single segment)
    const es = zpage() orelse {
        owos.klog.err("XHCI: OOM erst", .{});
        return;
    };
    w64(es.v, er.phys);
    w32(es.v + 8, RING_N);

    // Interrupter 0
    const ir0 = rt_base + 0x20;
    w32(ir0 + 8, 1);
    w64(ir0 + 0x18, er.phys);
    w64(ir0 + 0x10, es.p);
    w32(ir0, r32(ir0) | 2);

    // Data buffer
    const db_pg = zpage() orelse {
        owos.klog.err("XHCI: OOM dbuf", .{});
        return;
    };
    dbuf_p = db_pg.p;
    dbuf_v = db_pg.v;

    // Start
    w32(op_base, r32(op_base) | 1 | (1 << 3));
    // Wait until HCHalted clears
    for (0..1_000_000) |_| {
        if (r32(op_base + 4) & 1 == 0) break;
    }
    const sts = r32(op_base + 4);
    owos.klog.info("XHCI: controller started, USBSTS={x:0>8}", .{sts});

    // Drain any pending events (e.g. port status changes from controller start)
    for (0..100) |_| {
        if (poll_evt() == null) break;
    }

    // Quick NOOP to verify command ring works
    ring_put(&cr, 0, 0, (23 << 10)); // TRB_NOOP = type 23
    db_ring(0, 0);
    const noop = wait_cmd();
    if (noop == null) {
        owos.klog.warn("XHCI: NOOP timeout — command ring broken", .{});
        return;
    }
    owos.klog.info("XHCI: command ring OK", .{});

    // Power on all ports (some controllers need explicit PP)
    for (1..n_ports + 1) |p| {
        const port: u32 = @truncate(p);
        const a = psc_addr(port);
        var ps = r32(a);
        if (ps & (1 << 9) == 0) { // PP not set
            ps &= ~@as(u32, (0x7F << 17) | (1 << 1)); // mask RW1C + PED
            ps |= (1 << 9); // set PP
            w32(a, ps);
        }
    }

    // Wait for devices to connect after controller reset + port power-on.
    // USB devices can take 100-500ms to re-establish connections.
    // Approximate ~500ms with a large spin (conservative).
    spin(200_000_000);

    if (!scan_ports()) {
        owos.klog.warn("XHCI: no USB mass storage device found", .{});
        return;
    }

    ready = true;
    owos.klog.info("XHCI: USB storage ready, slot={d}", .{sid});
}

// ── Port management ────────────────────────────────────────────────────

fn reset_port(p: u32) bool {
    const a = psc_addr(p);
    // Set PR, preserve PP (bit 9), mask RW1C bits (17-23) and PED (bit 1)
    var ps = r32(a);
    ps &= ~@as(u32, (0x7F << 17) | (1 << 1)); // mask out RW1C + PED
    ps |= (1 << 4); // PR
    w32(a, ps);
    for (0..10_000_000) |_| {
        if (r32(a) & (1 << 21) != 0) {
            w32(a, (r32(a) & (1 << 9)) | (1 << 21)); // clear PRC, preserve PP
            // USB 2.0 spec: 10ms reset recovery time before first transaction
            spin(3_000_000);
            return r32(a) & 2 != 0; // PED?
        }
    }
    owos.klog.warn("XHCI: port{d} reset timeout (PORTSC={x:0>8})", .{ p, r32(a) });
    return false;
}

fn dump_protocols() void {
    const hcc1 = r32(cap_base + 0x10);
    const ecp = (hcc1 >> 16) & 0xFFFF;
    if (ecp == 0) return;

    var off: u64 = @as(u64, ecp) << 2;
    while (off != 0) {
        const addr = cap_base + off;
        const cap = r32(addr);
        const id = cap & 0xFF;

        if (id == 2) { // Supported Protocol
            const name_lo = r32(addr + 4);
            const w2 = r32(addr + 8);
            const port_off: u32 = w2 & 0xFF;
            const port_cnt: u32 = (w2 >> 8) & 0xFF;
            const rev_maj: u32 = (cap >> 24) & 0xFF;
            const rev_min: u32 = (cap >> 16) & 0xFF;
            // name_lo is ASCII "USB " = 0x20425355
            _ = name_lo;
            owos.klog.info("XHCI: protocol USB {d}.{d} ports {d}-{d}", .{
                rev_maj, rev_min, port_off, port_off + port_cnt - 1,
            });
        }

        const next = (cap >> 8) & 0xFF;
        if (next == 0) break;
        off += @as(u64, next) << 2;
    }
}

fn scan_ports() bool {
    dump_protocols();

    owos.klog.info("XHCI: scanning {d} ports...", .{n_ports});
    // Log ALL ports, not just connected ones
    for (1..n_ports + 1) |p| {
        const port: u32 = @truncate(p);
        const ps = r32(psc_addr(port));
        owos.klog.info("XHCI: port {d}: PORTSC={x:0>8}", .{ port, ps });
    }

    for (1..n_ports + 1) |p| {
        const port: u32 = @truncate(p);
        const ps = r32(psc_addr(port));
        const ccs = ps & 1;
        const ped = (ps >> 1) & 1;
        const port_spd = (ps >> 10) & 0xF;
        const pls = (ps >> 5) & 0xF;
        const pp = (ps >> 9) & 1;

        if (ccs != 0 or ped != 0) {
            owos.klog.info("XHCI: port {d}: PORTSC={x:0>8} CCS={d} PED={d} SPD={d} PLS={d} PP={d}", .{ port, ps, ccs, ped, port_spd, pls, pp });
        }

        if (ccs == 0) continue;

        // Reset port if not yet enabled
        if (ped == 0) {
            owos.klog.info("XHCI: resetting port {d}...", .{port});
            if (!reset_port(port)) {
                owos.klog.warn("XHCI: port {d} reset failed", .{port});
                continue;
            }
            owos.klog.info("XHCI: port {d} reset OK, PORTSC={x:0>8}", .{ port, r32(psc_addr(port)) });
        }

        const new_spd = (r32(psc_addr(port)) >> 10) & 0xF;
        if (new_spd == 0) continue;

        if (enumerate_device(port, new_spd)) return true;
    }
    return false;
}

// ── Device enumeration ─────────────────────────────────────────────────

fn enumerate_device(port: u32, port_spd: u32) bool {
    owos.klog.info("XHCI: enumerating port {d} spd={d}", .{ port, port_spd });
    // Enable slot
    ring_put(&cr, 0, 0, TRB_ENABLE_SLOT << 10);
    db_ring(0, 0);
    const es = wait_cmd() orelse {
        owos.klog.warn("XHCI: Enable Slot timeout USBSTS={x:0>8} CRCR={x:0>16}", .{
            r32(op_base + 4),
            @as(u64, r32(op_base + 0x18)) | (@as(u64, r32(op_base + 0x1C)) << 32),
        });
        return false;
    };
    if (es.cc != CC_SUCCESS or es.slot_id == 0) {
        owos.klog.warn("XHCI: Enable Slot failed cc={d} slot={d}", .{ es.cc, es.slot_id });
        return false;
    }
    sid = es.slot_id;
    spd = port_spd;
    prt = port;
    owos.klog.info("XHCI: got slot {d}", .{sid});

    // Allocate contexts + EP0 ring
    const dc = zpage() orelse {
        owos.klog.warn("XHCI: OOM dctx", .{});
        return false;
    };
    dctx_p = dc.p;
    dctx_v = dc.v;
    const ic = zpage() orelse {
        owos.klog.warn("XHCI: OOM ictx", .{});
        return false;
    };
    ictx_p = ic.p;
    ictx_v = ic.v;
    if (!ring_new(&ep0r)) {
        owos.klog.warn("XHCI: OOM ep0 ring", .{});
        return false;
    }

    // DCBAA[slot] = device context
    @as(*volatile u64, @ptrFromInt(dcbaa_v + @as(u64, sid) * 8)).* = dctx_p;

    const mps0: u32 = switch (port_spd) {
        2 => 8, // Low
        4 => 512, // Super
        else => 64, // Full/High
    };

    // Build input context for Address Device
    setup_addr_ctx(1, mps0);

    if (!do_address_device(mps0)) return false;
    owos.klog.info("XHCI: slot {d} addressed", .{sid});

    // GET_DESCRIPTOR(Device)
    var dev_desc: [18]u8 = undefined;
    const dn = ctrl_in(0x80, 6, 0x0100, 0, 18) orelse {
        owos.klog.warn("XHCI: GET_DESCRIPTOR(Device) failed", .{});
        return false;
    };
    if (dn < 8) {
        owos.klog.warn("XHCI: device descriptor too short ({d})", .{dn});
        return false;
    }
    const src: [*]const u8 = @ptrFromInt(dbuf_v);
    @memcpy(&dev_desc, src[0..18]);

    // Update EP0 max packet size if needed
    const real_mps: u32 = dev_desc[7];
    if (real_mps != 0 and real_mps != @as(u8, @truncate(mps0))) {
        const p2: [*]volatile u8 = @ptrFromInt(ictx_v);
        for (0..4096) |i| p2[i] = 0;
        w32(ictx_v + 4, 1 << 1); // Add EP0
        w32(ictx_v + 2 * csz + 4, (3 << 1) | (4 << 3) | (real_mps << 16));
        ring_put(&cr, ictx_p, 0, (TRB_EVAL_CTX << 10) | (@as(u32, sid) << 24));
        db_ring(0, 0);
        _ = wait_cmd();
    }

    // GET_DESCRIPTOR(Configuration, header only)
    _ = ctrl_in(0x80, 6, 0x0200, 0, 9) orelse return false;
    var conf_buf: [4096]u8 = undefined;
    const cs: [*]const u8 = @ptrFromInt(dbuf_v);
    @memcpy(conf_buf[0..9], cs[0..9]);
    const total_len = std.mem.readInt(u16, conf_buf[2..4], .little);
    const cap_len: u16 = @intCast(@min(total_len, 4096));

    // GET full configuration descriptor
    _ = ctrl_in(0x80, 6, 0x0200, 0, cap_len) orelse return false;
    const cs2: [*]const u8 = @ptrFromInt(dbuf_v);
    @memcpy(conf_buf[0..cap_len], cs2[0..cap_len]);

    owos.klog.info("XHCI: config descriptor total_len={d}", .{total_len});

    // Find mass storage interface with bulk endpoints
    const eps = find_msc_eps(conf_buf[0..cap_len]) orelse {
        owos.klog.info("XHCI: port {d} device is not mass storage (class={x} sub={x})", .{ port, dev_desc[4], dev_desc[5] });
        return false;
    };

    // SET_CONFIGURATION
    _ = ctrl_out_nodata(0x00, 9, @as(u16, conf_buf[5]), 0) orelse {
        owos.klog.warn("XHCI: SET_CONFIGURATION failed", .{});
        return false;
    };

    // Allocate bulk rings
    if (!ring_new(&bir) or !ring_new(&bor)) return false;

    bi_dci = @as(u32, eps.in_num) * 2 + 1;
    bo_dci = @as(u32, eps.out_num) * 2;
    const max_dci = @max(bi_dci, bo_dci);

    // Configure endpoints
    const cp: [*]volatile u8 = @ptrFromInt(ictx_v);
    for (0..4096) |i| cp[i] = 0;

    // Add flags: slot + both bulk endpoints
    w32(ictx_v + 4, (1 << 0) | (@as(u32, 1) << @truncate(bi_dci)) | (@as(u32, 1) << @truncate(bo_dci)));

    // Slot context
    w32(ictx_v + csz, (spd << 20) | (max_dci << 27));
    w32(ictx_v + csz + 4, prt << 16);

    // Bulk IN context
    const bi_off = ictx_v + (bi_dci + 1) * csz;
    w32(bi_off + 4, (3 << 1) | (6 << 3) | (@as(u32, eps.in_mps) << 16));
    w64(bi_off + 8, bir.phys | 1);
    w32(bi_off + 16, 1024);

    // Bulk OUT context
    const bo_off = ictx_v + (bo_dci + 1) * csz;
    w32(bo_off + 4, (3 << 1) | (2 << 3) | (@as(u32, eps.out_mps) << 16));
    w64(bo_off + 8, bor.phys | 1);
    w32(bo_off + 16, 1024);

    ring_put(&cr, ictx_p, 0, (TRB_CONFIG_EP << 10) | (@as(u32, sid) << 24));
    db_ring(0, 0);
    const ce = wait_cmd() orelse return false;
    if (ce.cc != CC_SUCCESS) {
        owos.klog.warn("XHCI: Configure EP failed cc={d}", .{ce.cc});
        return false;
    }

    owos.klog.info("XHCI: mass storage port={d} speed={d} IN=EP{d} OUT=EP{d}", .{ port, port_spd, eps.in_num, eps.out_num });
    return true;
}

fn do_address_device(mps0: u32) bool {
    // Verify port is still good before addressing
    const ps_before = r32(psc_addr(prt));
    owos.klog.info("XHCI: pre-addr PORTSC={x:0>8} CCS={d} PED={d} SPD={d}", .{
        ps_before,
        ps_before & 1,
        (ps_before >> 1) & 1,
        (ps_before >> 10) & 0xF,
    });
    if (ps_before & 3 != 3) {
        owos.klog.warn("XHCI: port not ready for addressing", .{});
        return false;
    }

    // Step 1: BSR=1 — load context into controller without USB transaction
    setup_addr_ctx(1, mps0);
    ring_put(&cr, ictx_p, 0, (TRB_ADDRESS_DEV << 10) | (1 << 9) | (@as(u32, sid) << 24));
    db_ring(0, 0);
    const bsr = wait_cmd() orelse {
        owos.klog.warn("XHCI: BSR=1 timeout", .{});
        return false;
    };
    if (bsr.cc != CC_SUCCESS) {
        owos.klog.warn("XHCI: BSR=1 failed cc={d}", .{bsr.cc});
        return false;
    }
    owos.klog.info("XHCI: BSR=1 OK (Default state)", .{});

    // Step 2: BSR=0 — now send SET_ADDRESS on wire
    // Re-submit input context (controller requires fresh submission)
    setup_addr_ctx(1, mps0);
    ring_put(&cr, ictx_p, 0, (TRB_ADDRESS_DEV << 10) | (@as(u32, sid) << 24));
    db_ring(0, 0);
    if (wait_cmd_n(10_000_000)) |ad| {
        if (ad.cc == CC_SUCCESS) {
            owos.klog.info("XHCI: slot {d} addressed OK", .{sid});
            return true;
        }
        owos.klog.warn("XHCI: Address Device failed cc={d} PORTSC={x:0>8}", .{
            ad.cc, r32(psc_addr(prt)),
        });
        return false;
    }

    // Timeout — check port state and try port re-reset + retry
    const ps_after = r32(psc_addr(prt));
    owos.klog.warn("XHCI: Address Device timeout PORTSC={x:0>8}", .{ps_after});
    abort_cmd();

    // Some devices need a second port reset after the first addressing attempt
    owos.klog.info("XHCI: retrying with port re-reset...", .{});
    if (!reset_port(prt)) return false;

    // Disable old slot and get a new one
    ring_put(&cr, 0, 0, (TRB_DISABLE_SLOT << 10) | (@as(u32, sid) << 24));
    db_ring(0, 0);
    _ = wait_cmd(); // don't care if it fails

    ring_put(&cr, 0, 0, TRB_ENABLE_SLOT << 10);
    db_ring(0, 0);
    const es2 = wait_cmd() orelse return false;
    if (es2.cc != CC_SUCCESS or es2.slot_id == 0) return false;
    sid = es2.slot_id;

    // Set up DCBAA for new slot
    const p2: [*]volatile u8 = @ptrFromInt(dctx_v);
    for (0..4096) |i| p2[i] = 0;
    @as(*volatile u64, @ptrFromInt(dcbaa_v + @as(u64, sid) * 8)).* = dctx_p;

    // Direct BSR=0 on fresh slot
    setup_addr_ctx(1, mps0);
    ring_put(&cr, ictx_p, 0, (TRB_ADDRESS_DEV << 10) | (@as(u32, sid) << 24));
    db_ring(0, 0);
    if (wait_cmd_n(10_000_000)) |ad2| {
        if (ad2.cc == CC_SUCCESS) {
            owos.klog.info("XHCI: slot {d} addressed OK (retry)", .{sid});
            return true;
        }
        owos.klog.warn("XHCI: retry failed cc={d}", .{ad2.cc});
    } else {
        owos.klog.warn("XHCI: retry timeout", .{});
        abort_cmd();
    }
    return false;
}

fn setup_addr_ctx(ctx_entries: u32, mps0: u32) void {
    const p2: [*]volatile u8 = @ptrFromInt(ictx_v);
    for (0..4096) |i| p2[i] = 0;

    // Input Control: Add slot (bit 0) + EP0 (bit 1)
    w32(ictx_v + 4, 3);

    // Slot context
    w32(ictx_v + csz, (spd << 20) | (ctx_entries << 27));
    w32(ictx_v + csz + 4, prt << 16);

    // EP0 context: CErr=3, Control bidirectional, max packet size
    w32(ictx_v + 2 * csz + 4, (3 << 1) | (4 << 3) | (mps0 << 16));
    w64(ictx_v + 2 * csz + 8, ep0r.phys | 1); // TR dequeue + DCS
    w32(ictx_v + 2 * csz + 16, 8); // avg TRB length
}

const MscEps = struct { in_num: u8, in_mps: u16, out_num: u8, out_mps: u16 };

fn find_msc_eps(desc: []const u8) ?MscEps {
    var i: usize = 0;
    var in_msc = false;
    var result: MscEps = .{ .in_num = 0, .in_mps = 0, .out_num = 0, .out_mps = 0 };

    while (i + 1 < desc.len) {
        const len = desc[i];
        if (len < 2 or i + len > desc.len) break;
        const dtype = desc[i + 1];

        if (dtype == 4 and len >= 9) {
            in_msc = (desc[i + 5] == 0x08 and desc[i + 6] == 0x06 and desc[i + 7] == 0x50);
        } else if (dtype == 5 and len >= 7 and in_msc) {
            const addr = desc[i + 2];
            const attrs = desc[i + 3];
            if (attrs & 3 == 2) { // Bulk
                const mps = std.mem.readInt(u16, desc[i + 4 ..][0..2], .little);
                if (addr & 0x80 != 0) {
                    result.in_num = addr & 0x0F;
                    result.in_mps = mps;
                } else {
                    result.out_num = addr & 0x0F;
                    result.out_mps = mps;
                }
            }
        }
        i += len;
    }

    if (result.in_num != 0 and result.out_num != 0) return result;
    return null;
}

// ── Control transfers ──────────────────────────────────────────────────

fn ctrl_in(rtype: u8, req: u8, val: u16, idx: u16, len: u16) ?usize {
    const setup = @as(u64, rtype) | (@as(u64, req) << 8) | (@as(u64, val) << 16) |
        (@as(u64, idx) << 32) | (@as(u64, len) << 48);
    const trt: u32 = if (len > 0) 3 else 0;

    ring_put(&ep0r, setup, 8, (TRB_SETUP << 10) | (1 << 6) | (trt << 16));
    if (len > 0)
        ring_put(&ep0r, dbuf_p, @as(u32, len), (TRB_DATA << 10) | (1 << 16));
    ring_put(&ep0r, 0, 0, (TRB_STATUS << 10) | (1 << 5) | (if (len > 0) @as(u32, 0) else @as(u32, 1 << 16)));

    db_ring(sid, 1);
    const ev = wait_xfer() orelse return null;
    if (ev.cc != CC_SUCCESS and ev.cc != CC_SHORT) return null;
    return @as(usize, len) -| @as(usize, ev.rem);
}

fn ctrl_out_nodata(rtype: u8, req: u8, val: u16, idx: u16) ?void {
    const setup = @as(u64, rtype) | (@as(u64, req) << 8) | (@as(u64, val) << 16) |
        (@as(u64, idx) << 32);
    ring_put(&ep0r, setup, 8, (TRB_SETUP << 10) | (1 << 6));
    ring_put(&ep0r, 0, 0, (TRB_STATUS << 10) | (1 << 5) | (1 << 16));
    db_ring(sid, 1);
    const ev = wait_xfer() orelse return null;
    if (ev.cc != CC_SUCCESS) return null;
}

// ── Bulk transfers ─────────────────────────────────────────────────────

pub fn is_connected() bool {
    if (!ready or prt == 0) return false;
    return r32(psc_addr(prt)) & 1 != 0; // CCS bit
}

pub fn bulk_out(data: []const u8) ?usize {
    if (!ready or data.len == 0) return null;
    if (!is_connected()) {
        owos.klog.warn("XHCI: device disconnected", .{});
        ready = false;
        return null;
    }
    const len: usize = @min(data.len, 4096);
    const dst: [*]volatile u8 = @ptrFromInt(dbuf_v);
    for (0..len) |i| dst[i] = data[i];
    ring_put(&bor, dbuf_p, @intCast(len), (TRB_NORMAL << 10) | (1 << 5));
    db_ring(sid, bo_dci);
    const ev = wait_xfer() orelse {
        owos.klog.warn("XHCI: bulk_out timeout len={d}", .{len});
        return null;
    };
    if (ev.cc != CC_SUCCESS and ev.cc != CC_SHORT) {
        owos.klog.warn("XHCI: bulk_out err cc={d} rem={d}", .{ ev.cc, ev.rem });
        return null;
    }
    return len -| @as(usize, ev.rem);
}

pub fn bulk_in(buf: []u8) ?usize {
    if (!ready or buf.len == 0) return null;
    if (!is_connected()) {
        owos.klog.warn("XHCI: device disconnected", .{});
        ready = false;
        return null;
    }
    const len: usize = @min(buf.len, 4096);
    ring_put(&bir, dbuf_p, @intCast(len), (TRB_NORMAL << 10) | (1 << 5));
    db_ring(sid, bi_dci);
    const ev = wait_xfer() orelse return null;
    if (ev.cc != CC_SUCCESS and ev.cc != CC_SHORT) return null;
    const got = len -| @as(usize, ev.rem);
    const s: [*]const u8 = @ptrFromInt(dbuf_v);
    @memcpy(buf[0..got], s[0..got]);
    return got;
}
