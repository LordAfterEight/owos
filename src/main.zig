const owos = @import("owos");

export fn _start() noreturn {

    owos.serial.writeln("\n=====================================================\n\nKernel loaded successfully");
    owos.fb.rendering.init_fb() catch { owos.serial.writeln("Failed to get framebuffer request"); };
    owos.fb.rendering.test_fb();
    owos.fb.rendering.print(2, 2, "Framebuffer test successful");

    while (true) {
        asm volatile ("hlt");
    }
}
