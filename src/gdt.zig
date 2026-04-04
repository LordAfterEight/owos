const owos = @import("root.zig");

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_DATA: u16 = 0x18;
pub const USER_CODE: u16 = 0x20;
pub const TSS_SEL: u16 = 0x28;

pub const TSS = extern struct {
    reserved0: u32 align(4) = 0,
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist1: u64 align(4) = 0,
    ist2: u64 align(4) = 0,
    ist3: u64 align(4) = 0,
    ist4: u64 align(4) = 0,
    ist5: u64 align(4) = 0,
    ist6: u64 align(4) = 0,
    ist7: u64 align(4) = 0,
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iopb: u16 = 104,
};

comptime {
    if (@sizeOf(TSS) != 104) @compileError("TSS size mismatch");
}

pub var tss: TSS = .{};

var df_stack: [4096]u8 align(16) = undefined;

fn encode_entry(base: u32, limit: u20, access: u8, flags: u4) u64 {
    var entry: u64 = 0;
    entry |= @as(u64, limit & 0xFFFF);
    entry |= @as(u64, base & 0xFFFF) << 16;
    entry |= @as(u64, (base >> 16) & 0xFF) << 32;
    entry |= @as(u64, access) << 40;
    entry |= @as(u64, @as(u4, @truncate(limit >> 16))) << 48;
    entry |= @as(u64, flags) << 52;
    entry |= @as(u64, (base >> 24) & 0xFF) << 56;
    return entry;
}

var table: [7]u64 align(16) = .{
    0, // 0x00: null
    encode_entry(0, 0xFFFFF, 0x9A, 0xA), // 0x08: kernel code (64-bit, DPL 0)
    encode_entry(0, 0xFFFFF, 0x92, 0xC), // 0x10: kernel data (DPL 0)
    encode_entry(0, 0xFFFFF, 0xF2, 0xC), // 0x18: user data   (DPL 3)
    encode_entry(0, 0xFFFFF, 0xFA, 0xA), // 0x20: user code   (64-bit, DPL 3)
    0, // 0x28: TSS low
    0, // 0x30: TSS high
};

const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

pub fn init() void {
    tss.ist1 = @intFromPtr(&df_stack) + df_stack.len;

    const tss_addr = @intFromPtr(&tss);
    table[5] = encode_entry(
        @truncate(tss_addr),
        @as(u20, @intCast(@sizeOf(TSS) - 1)),
        0x89,
        0x0,
    );
    table[6] = tss_addr >> 32;

    const ptr = GdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(table)) - 1),
        .base = @intFromPtr(&table),
    };

    asm volatile (
        \\lgdt (%[ptr])
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        \\xor %%ax, %%ax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov $0x28, %%ax
        \\ltr %%ax
        :
        : [ptr] "r" (&ptr),
        : .{ .rax = true, .memory = true }
    );

    owos.serial.writeln("GDT loaded");
}

pub fn set_kernel_stack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}
