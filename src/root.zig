//! By convention, root.zig is the root source file when making a library.
const zig_std = @import("std");

pub const c = @cImport({
    @cInclude("std/string.h");
    @cInclude("std/mem.h");
    @cInclude("std/std.h");
    @cInclude("gdt.h");
    @cInclude("rendering.h");
    @cInclude("time.h");
    @cInclude("timer.h");
    @cInclude("idt.h");
    @cInclude("pic.h");
    @cInclude("limine.h");
    @cInclude("drivers/ps2.h");
    @cInclude("sound/pcspeaker.h");
    @cInclude("fonts/OwOSFont_8x16.h");
});

pub const serial = @import("serial/serial.zig");
pub const process = @import("process/process.zig");
pub const shell = @import("shell/shell_definitions.zig");
pub const scheduler = @import("scheduler/scheduler_cooperative.zig");
pub const ui = struct{
    pub const taskbar = @import("ui/taskbar.zig");
    pub const window = @import("ui/window.zig");
};
pub const std = @import("std/std.zig");
pub const fs = @import("ramfs/ramfs.zig");
