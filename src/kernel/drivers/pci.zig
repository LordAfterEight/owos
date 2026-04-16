const owos = @import("../root.zig");

const CONFIG_ADDR: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub fn config_read32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const addr: u32 = (1 << 31) |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    outl(CONFIG_ADDR, addr);
    return inl(CONFIG_DATA);
}

pub fn config_write32(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    const addr: u32 = (1 << 31) |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    outl(CONFIG_ADDR, addr);
    outl(CONFIG_DATA, value);
}

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device_id: u16,
    bar0: u64,
    irq: u8,
};

// ── Full-bus recursive enumeration ─────────────────────────────────────

const SearchKind = enum { by_class, by_class_progif, by_vendor };
const SearchParams = struct {
    class: u8 = 0,
    subclass: u8 = 0,
    progif: u8 = 0,
    vendor: u16 = 0,
    device_id: u16 = 0,
    kind: SearchKind = .by_class,
};

fn check_function(bus: u8, slot: u8, func: u8, params: SearchParams) ?Device {
    const id = config_read32(bus, slot, func, 0);
    if (id == 0xFFFFFFFF or @as(u16, @truncate(id)) == 0xFFFF) return null;

    const class_reg = config_read32(bus, slot, func, 0x08);
    const cls: u8 = @truncate(class_reg >> 24);
    const subcls: u8 = @truncate(class_reg >> 16);
    const progif: u8 = @truncate(class_reg >> 8);
    const v: u16 = @truncate(id);
    const d: u16 = @truncate(id >> 16);

    const matched = switch (params.kind) {
        .by_class => cls == params.class and subcls == params.subclass,
        .by_class_progif => cls == params.class and subcls == params.subclass and progif == params.progif,
        .by_vendor => v == params.vendor and d == params.device_id,
    };

    if (matched) {
        const bar0_val = config_read32(bus, slot, func, 0x10);
        const irq_line: u8 = @truncate(config_read32(bus, slot, func, 0x3C));
        // Enable bus mastering and memory space access
        const cmd = config_read32(bus, slot, func, 0x04);
        config_write32(bus, slot, func, 0x04, cmd | 0x06);
        return .{
            .bus = bus,
            .slot = slot,
            .func = func,
            .vendor = v,
            .device_id = d,
            .bar0 = bar0_val & 0xFFFFFFF0,
            .irq = irq_line,
        };
    }

    return null;
}

fn scan_bus(bus: u8, params: SearchParams, depth: u8) ?Device {
    if (depth > 8) return null; // prevent infinite recursion

    for (0..32) |slot_u| {
        const slot: u8 = @truncate(slot_u);
        const id = config_read32(bus, slot, 0, 0);
        if (id == 0xFFFFFFFF or @as(u16, @truncate(id)) == 0xFFFF) continue;

        // Determine number of functions
        const hdr = config_read32(bus, slot, 0, 0x0C);
        const multi = (hdr >> 16) & 0x80 != 0;
        const n_func: u8 = if (multi) 8 else 1;

        for (0..n_func) |func_u| {
            const func: u8 = @truncate(func_u);
            if (func > 0) {
                const fid = config_read32(bus, slot, func, 0);
                if (fid == 0xFFFFFFFF or @as(u16, @truncate(fid)) == 0xFFFF) continue;
            }

            // Check if this function matches
            if (check_function(bus, slot, func, params)) |dev| return dev;

            // If this is a PCI-to-PCI bridge (class 06, subclass 04), recurse
            const cr = config_read32(bus, slot, func, 0x08);
            if (@as(u8, @truncate(cr >> 24)) == 0x06 and @as(u8, @truncate(cr >> 16)) == 0x04) {
                const bridge_reg = config_read32(bus, slot, func, 0x18);
                const secondary_bus: u8 = @truncate(bridge_reg >> 8);
                if (secondary_bus != 0 and secondary_bus != bus) {
                    if (scan_bus(secondary_bus, params, depth + 1)) |dev| return dev;
                }
            }
        }
    }
    return null;
}

// ── Public API ─────────────────────────────────────────────────────────

/// Find a PCI device by class/subclass. Scans all buses recursively.
pub fn find_by_class(class: u8, subclass: u8) ?Device {
    return scan_bus(0, .{ .kind = .by_class, .class = class, .subclass = subclass }, 0);
}

/// Find a PCI device by class/subclass/progIF. Scans all buses recursively.
pub fn find_by_class_progif(class: u8, subclass: u8, progif: u8) ?Device {
    return scan_bus(0, .{ .kind = .by_class_progif, .class = class, .subclass = subclass, .progif = progif }, 0);
}

/// Find a PCI device by vendor/device ID. Scans all buses recursively.
pub fn find_device(vendor: u16, device_id: u16) ?Device {
    return scan_bus(0, .{ .kind = .by_vendor, .vendor = vendor, .device_id = device_id }, 0);
}
