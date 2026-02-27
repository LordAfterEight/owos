const std = @import("std");
const owos = @import("owos");

const init_bin = @embedFile("userland/init.bin");

fn hcf() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

comptime {
    @export(&owos.syscall.syscall_dispatch, .{ .name = "syscall80_dispatch", .linkage = .strong });
}


pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

extern fn enable_sse() void;

var scheduler: *owos.scheduler.Scheduler = undefined;

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

    //owos.c.pit_init(1000);
    owos.serial.println("K: PIT initialized");

    asm volatile ("sti");
    owos.serial.println("L: Interrupts enabled");

    const resp_ptr = owos.c.hhdm_request.response;
    if (resp_ptr == null) {
        owos.serial.println("hhdm_response = null");
        hcf();
    }
    owos.serial.print("hhdm_response ptr = ");
    owos.serial.print_hex_u64(@intFromPtr(resp_ptr.?));
    owos.serial.println("");

    const hhdm_offset: u64 = resp_ptr.*.offset;

    const memmap_resp = @as(*owos.c.struct_limine_memmap_response,
        @ptrCast(@alignCast(owos.c.memmap_request.response orelse hcf())));
    owos.pmm.pmm_init(
        memmap_resp,
        hhdm_offset,
    );

    scheduler = owos.scheduler.Scheduler.init();

    _ = scheduler.spawn_user_process("init", init_bin) catch unreachable;

    scheduler.run();
}
