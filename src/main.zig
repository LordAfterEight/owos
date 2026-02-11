const std = @import("std");
const owos = @import("owos");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

fn serial_print(msg: []const u8) void {
    for (msg) |char| {
        owos.c.outb(0x3F8, char);
    }
    owos.c.outb(0x3F8, '\n');
    owos.c.outb(0x3F8, '\r');
}

pub export fn _start() callconv(.c) noreturn {
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

    owos.c.shell_init();
    serial_print("K: Shell initialized");
    owos.c.clear_screen();

    owos.c.pic_remap();
    serial_print("I: PIC remapped");

    owos.c.idt_init();
    serial_print("H: IDT initialized");

    owos.c.outb(0x21, 0xFF);
    owos.c.outb(0xA1, 0xFF);
    owos.c.outb(0x21, owos.c.inb(0x21) & ~@as(u8, 1 << 0));
    serial_print("PIC masked, IRQ0 unmasked\n");

    owos.c.pit_init(1000);
    serial_print("J: PIT initialized");

    asm volatile ("sti");
    serial_print("L: Interrupts enabled");

    owos.c.greet();
    const result: c_int = owos.c.shell_process.run.?(owos.c.shell);
    _ = result;
    serial_print("M: Shell process returned");
    hcf();
}
