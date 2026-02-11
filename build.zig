const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Module for C imports
    const owos_c_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = false,
        .strip = false,
        .sanitize_c = .off,
        .optimize = .ReleaseSmall,
    });

    owos_c_module.addIncludePath(b.path("src"));

    // Executable - create module from main.zig
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

    // C sources
    exe.addCSourceFiles(.{
        .files = &.{
            "src/prerequisites.c",
            "src/rendering.c",
            "src/shell/shell_definitions.c",
            "src/std/mem.c",
            "src/std/std.c",
            "src/std/string.c",
            "src/time.c",
            "src/timer.c",
            "src/idt.c",
            "src/gdt.c",
            "src/pic.c",
            "src/sound/pcspeaker.c",
            "src/drivers/ps2.c",
            "src/fonts/OwOSFont_8x16.c",
            "src/process/process.c",
            "src/ramfs/ramfs.c",
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

    exe.setLinkerScript(b.path("linker.lds"));
    exe.link_gc_sections = false;
    b.installArtifact(exe);
}
