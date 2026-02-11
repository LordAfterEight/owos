const std = @import("std");
const owos = @import("owos");
const shell_lib = @import("shell/shell_definitions.zig");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

fn serial_putc(c: u8) void {
    owos.c.outb(0x3F8, c);
}

fn serial_print(msg: []const u8) void {
    for (msg) |ch| serial_putc(ch);
    serial_putc('\n');
    serial_putc('\r');
}

fn serial_print_hex_u64(x: u64) void {
    serial_putc('0');
    serial_putc('x');

    var shift: u6 = 60;
    while (true) {
        const nib: u4 = @truncate(x >> shift);
        const digit: u8 = if (nib < 10) ('0' + @as(u8, nib)) else ('A' + @as(u8, nib - 10));
        serial_putc(digit);
        if (shift == 0) break;
        shift -= 4;
    }

    serial_putc('\n');
    serial_putc('\r');
}

fn serial_print_dec_usize(v_in: usize) void {
    var v = v_in;
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;

    if (v == 0) {
        serial_putc('0');
        serial_putc('\n');
        serial_putc('\r');
        return;
    }

    while (v != 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }

    for (buf[i..]) |ch| serial_putc(ch);
    serial_putc('\n');
    serial_putc('\r');
}

fn read_rsp() usize {
    return asm volatile ("" : [out] "={rsp}" (-> usize));
}

extern fn enable_sse() void;

pub export fn kmain() callconv(.c) noreturn {
    enable_sse();
    serial_print("A: kmain started");
    if (owos.c.limine_base_revision[2] != 0) hcf();
    serial_print("B: base revision OK");

    const fb_response: [*c]owos.c.struct_limine_framebuffer_response =
        @ptrCast(@alignCast(owos.c.framebuffer_request.response orelse hcf()));
    serial_print("C: got framebuffer response");

    if (fb_response.*.framebuffer_count < 1) hcf();
    serial_print("D: framebuffer count OK");

    const framebuffer: [*c]owos.c.struct_limine_framebuffer = fb_response.*.framebuffers[0];
    serial_print("E: got framebuffer");

    owos.c.global_framebuffer = @ptrCast(@alignCast(framebuffer.*.address));
    serial_print("F: globals set");

    owos.c.gdt_init();
    serial_print("G: GDT initialized");

    owos.c.outb(0x21, 0xFF);
    owos.c.outb(0xA1, 0xFF);
    owos.c.outb(0x21, owos.c.inb(0x21) & ~@as(u8, 1 << 0));
    serial_print("PIC masked, IRQ0 unmasked\n");

    var shell = shell_lib.Shell.init();

    owos.c.idt_init();
    serial_print("H: IDT initialized");

    serial_print("I: Shell initialized");

    owos.c.pic_remap();
    serial_print("J: PIC remapped");

    owos.c.pit_init(1000);
    serial_print("K: PIT initialized");

    asm volatile ("sti");
    serial_print("L: Interrupts enabled");

    shell.clear();
    shell.greet(&owos.c.OwOSFont_8x16);
    //const result: c_int = owos.c.shell_process.run.?(owos.c.shell);
    //_ = result;
    serial_print("M: Shell process returned");
    hcf();
}
