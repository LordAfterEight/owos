const owos = @import("owos");

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movabsq $__stack_top, %%rsp
        \\call kmain
    );
}

extern const __stack_top: u8;

export fn kmain() noreturn {
    owos.serial.writeln("\n=====================================================\n\nKernel loaded successfully");

    owos.gdt.init();
    owos.idt.init();

    owos.fb.rendering.init_fb() catch {
        owos.serial.writeln("Failed to get framebuffer request");
        while (true) asm volatile ("hlt");
    };

    //owos.fb.rendering.test_fb();

    const logging = owos.fb.rendering.ScrollingLog.init();
    logging.println("Kernel loaded successfully", owos.fb.rendering.Color.DarkGrey);
    logging.println("GDT and IDT initialized", owos.fb.rendering.Color.BrightYellow);
    logging.println("Framebuffer initialized", owos.fb.rendering.Color.BrightYellow);

    while (true) {
        asm volatile ("hlt");
    }
}
