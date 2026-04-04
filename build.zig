const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const Target = std.Target.x86;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .mmx }),
    });

    const limine_module = b.createModule(.{
        .root_source_file = b.path("src/limine.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    const owos_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    root_module.addImport("limine", limine_module);
    root_module.addImport("owos", owos_module);

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = root_module,
    });
    kernel.setLinkerScript(b.path("src/linker.ld"));
    kernel.use_lld = true;
    kernel.use_llvm = true;

    // Assemble the ISO root directory using system limine files
    const limine_share = "/usr/share/limine";
    const iso_files = b.addWriteFiles();
    _ = iso_files.addCopyFile(kernel.getEmittedBin(), "boot/kernel.elf");
    _ = iso_files.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");
    _ = iso_files.addCopyFile(.{ .cwd_relative = limine_share ++ "/limine-bios.sys" }, "boot/limine/limine-bios.sys");
    _ = iso_files.addCopyFile(.{ .cwd_relative = limine_share ++ "/limine-bios-cd.bin" }, "boot/limine/limine-bios-cd.bin");
    _ = iso_files.addCopyFile(.{ .cwd_relative = limine_share ++ "/limine-uefi-cd.bin" }, "boot/limine/limine-uefi-cd.bin");
    _ = iso_files.addCopyFile(.{ .cwd_relative = limine_share ++ "/BOOTX64.EFI" }, "EFI/BOOT/BOOTX64.EFI");
    _ = iso_files.addCopyFile(.{ .cwd_relative = limine_share ++ "/BOOTIA32.EFI" }, "EFI/BOOT/BOOTIA32.EFI");

    // Build the ISO with xorriso
    const xorriso = b.addSystemCommand(&.{
        "xorriso", "-as", "mkisofs",
        "-b",              "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size", "4",
        "-boot-info-table",
        "--efi-boot",      "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
        "-o",
    });
    const iso_file = xorriso.addOutputFileArg("kernel.iso");
    xorriso.addDirectoryArg(iso_files.getDirectory());

    // Deploy Limine BIOS bootloader onto the ISO in-place
    const limine_bios = b.addSystemCommand(&.{ "limine", "bios-install" });
    limine_bios.addFileArg(iso_file);

    // Install the ISO as the default build output
    const install_iso = b.addInstallFile(iso_file, "kernel.iso");
    install_iso.step.dependOn(&limine_bios.step);
    b.getInstallStep().dependOn(&install_iso.step);

    // Run QEMU with the ISO
    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-m",      "1G",
        "-serial", "stdio",
        "-cdrom",
    });
    qemu.addFileArg(iso_file);
    qemu.step.dependOn(&limine_bios.step);

    const run_step = b.step("run", "Build ISO and run with QEMU");
    run_step.dependOn(&qemu.step);
}
