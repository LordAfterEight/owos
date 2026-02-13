const std = @import("std");
const owos = @import("owos");
const shell_lib = @import("shell/shell_definitions.zig");
const process_lib = @import("process/process.zig");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}


fn read_rsp() usize {
    return asm volatile ("" : [out] "={rsp}" (-> usize));
}

extern fn enable_sse() void;

pub export fn kmain() callconv(.c) noreturn {
    enable_sse();
    owos.serial.serial_print("A: kmain started");
    if (owos.c.limine_base_revision[2] != 0) hcf();
    owos.serial.serial_print("B: base revision OK");

    const fb_response: [*c]owos.c.struct_limine_framebuffer_response =
        @ptrCast(@alignCast(owos.c.framebuffer_request.response orelse hcf()));
    owos.serial.serial_print("C: got framebuffer response");

    if (fb_response.*.framebuffer_count < 1) hcf();
    owos.serial.serial_print("D: framebuffer count OK");

    const framebuffer: [*c]owos.c.struct_limine_framebuffer = fb_response.*.framebuffers[0];
    owos.serial.serial_print("E: got framebuffer");

    owos.c.global_framebuffer = @ptrCast(@alignCast(framebuffer.*.address));
    owos.serial.serial_print("F: globals set");

    owos.c.gdt_init();
    owos.serial.serial_print("G: GDT initialized");

    owos.c.outb(0x21, 0xFF);
    owos.c.outb(0xA1, 0xFF);
    owos.c.outb(0x21, owos.c.inb(0x21) & ~@as(u8, 1 << 0));
    owos.serial.serial_print("PIC masked, IRQ0 unmasked\n");

    var shell = shell_lib.Shell.init();

    owos.c.idt_init();
    owos.serial.serial_print("H: IDT initialized");

    owos.serial.serial_print("I: Shell initialized");

    owos.c.pic_remap();
    owos.serial.serial_print("J: PIC remapped");

    owos.c.pit_init(1000);
    owos.serial.serial_print("K: PIT initialized");

    asm volatile ("sti");
    owos.serial.serial_print("L: Interrupts enabled");

    var shell_process = process_lib.Process.init_mut(1, &shell);
    const result = shell_process.run();
    switch (result) {
        1 => owos.serial.serial_print("Shell process terminated with exit code 1"),
        0 => owos.serial.serial_print("Shell process closed successfully"),
        else => owos.serial.serial_print("Invalid exit code"),
    }
    hcf();
}
