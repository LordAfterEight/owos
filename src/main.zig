const std = @import("std");
const owos = @import("owos");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

extern fn enable_sse() void;

pub export fn kmain() callconv(.c) noreturn {
    enable_sse();
    owos.serial.println("A: kmain started");
    if (owos.c.limine_base_revision[2] != 0) hcf();
    owos.serial.println("B: base revision OK");

    const fb_response: [*c]owos.c.struct_limine_framebuffer_response =
        @ptrCast(@alignCast(owos.c.framebuffer_request.response orelse hcf()));
    owos.serial.println("C: got framebuffer response");

    if (fb_response.*.framebuffer_count < 1) hcf();
    owos.serial.println("D: framebuffer count OK");

    const framebuffer: [*c]owos.c.struct_limine_framebuffer = fb_response.*.framebuffers[0];
    owos.serial.println("E: got framebuffer");

    owos.c.global_framebuffer = @ptrCast(@alignCast(framebuffer.*.address));
    owos.serial.println("F: globals set");

    owos.c.gdt_init();
    owos.serial.println("G: GDT initialized");

    owos.c.outb(0x21, 0xFF);
    owos.c.outb(0xA1, 0xFF);
    owos.c.outb(0x21, owos.c.inb(0x21) & ~@as(u8, 1 << 0));
    owos.serial.println("PIC masked, IRQ0 unmasked\n");

    owos.c.idt_init();
    owos.serial.println("H: IDT initialized");

    owos.serial.println("I: Shell initialized");

    owos.c.pic_remap();
    owos.serial.println("J: PIC remapped");

    owos.c.pit_init(1000);
    owos.serial.println("K: PIT initialized");

    asm volatile ("sti");
    owos.serial.println("L: Interrupts enabled");

    var scheduler = owos.scheduler.CooperativeScheduler.init();

    var shell = owos.shell.Shell.init();
    const taskbar = owos.ui.taskbar.TaskBar.init();

    var shell_process = owos.process.Process.init_mut(&shell);
    scheduler.add_process(&shell_process);

    const memory = owos.fs.RawStorage.init();

    var taskbar_process = owos.process.Process.init_mut(&taskbar);
    scheduler.add_process(&taskbar_process);

    shell.greet(&owos.c.OwOSFont_8x16);
    shell.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
    scheduler.run();
    _ = memory;
}
