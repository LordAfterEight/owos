const std = @import("std");
const owos = @import("root.zig");
const gdt = @import("gdt.zig");

pub const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const Handler = *const fn (*InterruptFrame) void;

var handlers: [256]?Handler = [_]?Handler{null} ** 256;

pub fn set_handler(vector: u8, handler: Handler) void {
    handlers[vector] = handler;
}

const IdtEntry = packed struct(u128) {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    reserved0: u5 = 0,
    gate_type: u4 = 0xE,
    zero: u1 = 0,
    dpl: u2 = 0,
    present: u1 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved1: u32 = 0,

    fn gate(offset: u64, ist: u3, dpl: u2) IdtEntry {
        return .{
            .offset_low = @truncate(offset),
            .selector = gdt.KERNEL_CODE,
            .ist = ist,
            .gate_type = 0xE,
            .dpl = dpl,
            .present = 1,
            .offset_mid = @truncate(offset >> 16),
            .offset_high = @truncate(offset >> 32),
        };
    }
};

comptime {
    if (@sizeOf(IdtEntry) != 16) @compileError("IDT entry size mismatch");
}

var idt_table: [256]IdtEntry = [_]IdtEntry{.{}} ** 256;

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};


fn has_error_code(comptime vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn stub_asm(comptime vector: u8) []const u8 {
    return (if (!has_error_code(vector)) "pushq $0\n" else "") ++
        std.fmt.comptimePrint("pushq ${d}\n", .{vector}) ++
        "jmp isrCommon";
}

fn make_stub(comptime vector: u8) *const fn () callconv(.naked) void {
    return &struct {
        fn handler() callconv(.naked) void {
            asm volatile (stub_asm(vector));
        }
    }.handler;
}

const stubs = blk: {
    var fns: [256]*const fn () callconv(.naked) void = undefined;
    for (0..256) |i| {
        fns[i] = make_stub(@intCast(i));
    }
    break :blk fns;
};


export fn isrCommon() callconv(.naked) void {
    asm volatile (
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rsi
        \\push %%rdi
        \\push %%rbp
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\mov %%rsp, %%rdi
        \\mov %%rsp, %%rbx
        \\and $-16, %%rsp
        \\cld
        \\call isrDispatch
        \\mov %%rbx, %%rsp
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rbp
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\add $16, %%rsp
        \\iretq
    );
}

export fn isrDispatch(frame: *InterruptFrame) void {
    if (handlers[@as(u8, @truncate(frame.vector))]) |handler| {
        handler(frame);
    } else {
        const hex = "0123456789ABCDEF";
        const v: u8 = @truncate(frame.vector);
        owos.serial.write("Unhandled interrupt: 0x");
        owos.serial.write_byte(hex[v >> 4]);
        owos.serial.write_byte(hex[v & 0xF]);
        owos.serial.write_byte('\n');
    }
}

pub fn init() void {
    for (0..256) |i| {
        const ist: u3 = if (i == 8) 1 else 0;
        idt_table[i] = IdtEntry.gate(@intFromPtr(stubs[i]), ist, 0);
    }

    const ptr = IdtPtr{
        .limit = @as(u16, @sizeOf(@TypeOf(idt_table)) - 1),
        .base = @intFromPtr(&idt_table),
    };

    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&ptr),
        : .{ .memory = true }
    );

    owos.serial.writeln("IDT loaded");
}
