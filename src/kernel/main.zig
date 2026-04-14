const owos = @import("owos");
const limine = @import("limine");

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

    // TODO: replace with a key derived from hardware entropy (RDRAND/RDSEED).
    const ramfs_key = [_]u8{
        0x3a, 0xf1, 0x7c, 0x04, 0xb8, 0x29, 0xe5, 0x6d,
        0x91, 0x0c, 0x52, 0xd7, 0x38, 0xaa, 0x14, 0xfe,
        0x67, 0x2b, 0x8e, 0x40, 0x1d, 0xc3, 0x75, 0x9f,
        0xbc, 0x06, 0xe8, 0x53, 0x24, 0xd0, 0x4b, 0x71,
    };
    owos.ramfs.init(ramfs_key);
    owos.ramfs.crypto_tests.run_all(.normal);
    owos.idt_tests.run_all(.normal);

    owos.klog.info("FB: {d}x{d}  bpp={d}  addr={x:0>16}", .{
        owos.fb.rendering.GFB_WIDTH,
        owos.fb.rendering.GFB_HEIGHT,
        owos.fb.rendering.GFB.bpp,
        @intFromPtr(owos.fb.rendering.GFB.address),
    });

    const logging = &owos.fb.rendering.ScrollingLog.instance;
    const C = owos.fb.rendering.Color;

    logging.newline();
    logging.println("//----------------------------------------------------------------------------------------------------------//", .{}, C.Grey);

    owos.klog.verbosity = .verbose;

    logging.newline();
    var file = owos.ramfs.File.new("TestFile") catch unreachable;
    logging.println("Created file: {s}", .{file.name()}, C.BrightYellow);

    var file2 = owos.ramfs.File.new("TestFile") catch unreachable;
    logging.println("Created file: {s}", .{file2.name()}, C.BrightYellow);
    _ = &file2;

    const written = file.write("Hello World!") catch 0;
    logging.println("Wrote {d} bytes to {s}", .{ written, file.name() }, C.BrightGreen);

    var read_buf: [256]u8 = undefined;
    const file_data = file.read_all(&read_buf) catch {
        owos.klog.err("FATAL: ramfs decryption failed", .{});
        while (true) asm volatile ("hlt");
    };

    logging.print("Read {d} bytes from file {s}:", .{file_data.len, file.name()}, C.BrightGreen);

    for (file_data) |byte| {
        if (byte != 0) {
            logging.print(" {X:0>2}", .{byte}, C.BrightMagenta);
        } else {
            logging.print(" {X:0>2}", .{byte}, C.Grey);
        }
    }

    while (true) {
        asm volatile ("hlt");
    }
}
