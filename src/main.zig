const std = @import("std");
const owos = @import("owos");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}


pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

var kernel_memory: [1024 * 1024 * 1024]u8 = undefined;


extern fn enable_sse() void;

var scheduler: *owos.scheduler.CooperativeScheduler = undefined;

export fn kmain() callconv(.c) noreturn {
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

    owos.c.draw_text(0, 0, "Reserving 1GiB of RAM...", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
    var fba = std.heap.FixedBufferAllocator.init(&kernel_memory);
    const allocator = fba.allocator();
    owos.c.draw_text(0, 16, "Done", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);

    scheduler = owos.scheduler.CooperativeScheduler.init();

    var owm = owos.process.Process.init(
        owos.ui.owm.WindowManager,
        allocator,
        .{ "OwOS Window Manager" }
    ) catch unreachable;

    var shell = owos.process.Process.init(
        owos.shell.Shell,
        allocator,
        .{ "Shelly" }
    ) catch unreachable;

    var taskbar = owos.process.Process.init(
        owos.ui.taskbar.TaskBar,
        allocator,
        .{ "Taskbar" }
    ) catch unreachable;

    //_ = owos.c.owos_memcpy(@ptrCast(@volatileCast(&owos.c.back_buffer.*)), @ptrCast(&owos.c.wallpaper.*), 1920*1080*4);
    for (0..owos.c.SCREEN_HEIGHT*owos.c.SCREEN_WIDTH) |i| {
        owos.c.back_buffer[i] = 0x008080;
    }
    scheduler.add_process(&owm);
    scheduler.add_process(&taskbar);
    scheduler.add_process(&shell);

    const rsp = asm volatile ("mov %%rsp, %[ret]" : [ret] "=r" (-> u64));
    owos.serial.print("RSP before run(): 0x");
    owos.serial.print_hex_u64(rsp);
    owos.serial.println("");

    scheduler.run();
}
