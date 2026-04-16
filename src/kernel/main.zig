const std = @import("std");
const owos = @import("owos");
const limine = @import("limine");

pub const panic = std.debug.FullPanic(kernel_panic);

fn kernel_panic(msg: []const u8, ret_addr: ?usize) noreturn {
    owos.klog.err("PANIC: {s} ret=0x{x}", .{ msg, ret_addr orelse 0 });
    while (true) asm volatile ("hlt");
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movabsq $__stack_top, %%rsp
        \\call kmain
    );
}

extern const __stack_top: u8;

fn enable_sse() void {
    var cr: u64 = undefined;
    asm volatile (
        \\mov %%cr0, %[v]
        \\and $-5, %[v]
        \\or $2, %[v]
        \\mov %[v], %%cr0
        : [v] "=r" (cr),
    );
    asm volatile (
        \\mov %%cr4, %[v]
        \\or $0x600, %[v]
        \\mov %[v], %%cr4
        : [v] "=r" (cr),
    );
}

export fn kmain() noreturn {
    enable_sse();
    var cr0: u64 = undefined;
    var cr4: u64 = undefined;
    asm volatile ("mov %%cr0, %[v]" : [v] "=r" (cr0));
    asm volatile ("mov %%cr4, %[v]" : [v] "=r" (cr4));

    // Bring up the framebuffer first so all subsequent klog calls appear on screen.
    owos.fb.rendering.init_fb() catch {
        owos.serial.writeln("FATAL: no framebuffer");
        while (true) asm volatile ("hlt");
    };
    owos.fb.rendering.test_fb(); // clears screen; everything logged after this is visible

    owos.klog.info("Kernel booting...", .{});
    owos.klog.info("SSE: CR0={x:0>16}  CR4={x:0>16}", .{ cr0, cr4 });

    owos.gdt.init();
    owos.idt.init();

    const memmap_resp = blk: {
        const ptr: *const volatile ?*limine.MemMapResponse = @ptrCast(&owos.pmm.memmap_request.response);
        break :blk ptr.* orelse {
            owos.klog.err("FATAL: no memory map from Limine", .{});
            while (true) asm volatile ("hlt");
        };
    };
    const hhdm_resp = blk: {
        const ptr: *const volatile ?*limine.HhdmResponse = @ptrCast(&owos.pmm.hhdm_request.response);
        break :blk ptr.* orelse {
            owos.klog.err("FATAL: no HHDM from Limine", .{});
            while (true) asm volatile ("hlt");
        };
    };

    owos.pmm.init(memmap_resp, hhdm_resp);
    owos.vmm.init();
    owos.vmm.map_range(owos.ramfs.RAMFS_BASE, owos.ramfs.RAMFS_SIZE, owos.vmm.Flags.WRITE | owos.vmm.Flags.NX);

    owos.fb.rendering.init_back_buffer();

    owos.rdrand.init();

    var ramfs_key: [32]u8 = undefined;
    owos.rdrand.fill(&ramfs_key);
    owos.ramfs.init(ramfs_key);
    // Wipe the stack copy immediately
    @memset(&ramfs_key, 0);
    owos.ramfs.crypto_tests.run_all(.quiet);
    owos.idt_tests.run_all(.quiet);

    owos.klog.info("FB: {d}x{d}  bpp={d}  addr={x:0>16}", .{
        owos.fb.rendering.GFB_WIDTH,
        owos.fb.rendering.GFB_HEIGHT,
        owos.fb.rendering.GFB.bpp,
        @intFromPtr(owos.fb.rendering.GFB.address),
    });

    owos.acpi.init();
    owos.xhci.init();
    owos.usb_storage.init();
    owos.ahci.init();
    owos.fat32.init();
    owos.net.init();
    owos.ps2.init();

    const logging = &owos.fb.rendering.ScrollingLog.instance;

    logging.newline();
    logging.println("//----------------------------------------------------------------------------------------------------------//", .{}, .Grey);

    logging.newline();

    owos.serial.enabled = false;
    owos.klog.warn("SERIAL: output disabled for security. Use 'serial on' in shell to re-enable", .{});

    var shell = owos.shell.Shell.init();
    shell.run();
}
