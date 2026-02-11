//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const c = @cImport({
    @cInclude("prerequisites.h");
    @cInclude("std/string.h");
    @cInclude("std/mem.h");
    @cInclude("std/std.h");
    @cInclude("gdt.h");
    @cInclude("rendering.h");
    @cInclude("process/process.h");
    @cInclude("shell/shell_definitions.h");
    @cInclude("time.h");
    @cInclude("timer.h");
    @cInclude("idt.h");
    @cInclude("pic.h");
    @cInclude("sound/pcspeaker.h");
    @cInclude("ramfs/ramfs.h");
    @cInclude("fonts/OwOSFont_8x16.h");
});

