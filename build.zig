const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
        .os_tag = .freestanding,
        .abi = .none,
    });

    const owos_c_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = false,
        .strip = false,
        .sanitize_c = .off,
        .optimize = .ReleaseSmall,
    });

    owos_c_module.addIncludePath(b.path("src"));

    const exe = b.addExecutable(.{
        .name = "owos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .omit_frame_pointer = false,
            .single_threaded = true,
            .unwind_tables = .none,
            .link_libc = false,
            .red_zone = false,
            .code_model = .kernel,
        }),
    });

    exe.root_module.addImport("owos", owos_c_module);
    exe.entry = .{ .symbol_name = "_start" };
    exe.addIncludePath(b.path("src"));

    exe.addCSourceFiles(.{
        .files = &.{
            "src/rendering.c",
            "src/std/mem.c",
            "src/std/std.c",
            "src/std/string.c",
            "src/time.c",
            "src/timer.c",
            "src/gdt.c",
            "src/idt.c",
            "src/pic.c",
            "src/sound/pcspeaker.c",
            "src/drivers/ps2.c",
            "src/fonts/OwOSFont_8x16.c",
            "src/limine_requests.c",
        },
        .flags = &.{
            "-g", "-O2", "-pipe", "-Wall", "-Wextra",
            "-Wno-unused-variable", "-Wno-date-time",
            "-std=gnu11", "-ffreestanding",
            "-fno-stack-protector", "-fno-stack-check",
            "-fno-lto", "-fno-PIC",
            "-ffunction-sections", "-fdata-sections",
            "-m64", "-march=x86-64", "-mabi=sysv",
            "-mno-80387", "-mno-mmx", "-mno-sse", "-mno-sse2",
            "-mno-red-zone", "-mcmodel=kernel",
        },
    });

    exe.root_module.addAssemblyFile(b.path("src/timer_asm.s"));
    exe.root_module.addAssemblyFile(b.path("src/start.s"));
    exe.root_module.addAssemblyFile(b.path("src/enable_sse.s"));

    const manual_opt = b.option([]const u8, "build_date", "Build date string (e.g. \"Feb 11 2026\")");

    const owned_date: []const u8 = if (manual_opt) |m| blk: {
        // duplicate so the memory is owned by the build allocator
        break :blk b.allocator.dupe(u8, m) catch @panic("OOM duplicating build_date");
    } else blk: {
        const res = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "date", "+%b %e %Y" },
        }) catch |err| std.debug.panic("failed to run `date`: {}", .{err}); // build() can't `try` [web:309]

        defer b.allocator.free(res.stdout);
        defer b.allocator.free(res.stderr);

        const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
        break :blk b.allocator.dupe(u8, trimmed) catch @panic("OOM copying date stdout");
    };

    const zbuf = b.allocator.allocSentinel(u8, owned_date.len, 0) catch @panic("OOM allocSentinel(build_date)");
    @memcpy(zbuf[0..owned_date.len], owned_date);
    const build_date_z: [:0]const u8 = zbuf[0..owned_date.len :0];

    const options = b.addOptions();
    options.addOption([:0]const u8, "build_date", build_date_z);
    exe.root_module.addOptions("build_options", options);

    exe.setLinkerScript(b.path("linker.lds"));
    exe.link_gc_sections = false;
    b.installArtifact(exe);
}
