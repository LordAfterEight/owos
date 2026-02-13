const process_lib = @import("../process/process.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn new(r: u8, g: u8, b: u8) Color {
        return Color {
            .r = r,
            .g = g,
            .b = b
        };
    }
};

pub const WindowColors = struct {
    bg: Color,
    border: Color,
};

pub const Window = struct {
    owned_process: process_lib.Process,
    title: []const u8,
    pos_x: usize,
    pos_y: usize,
    width: usize,
    height: usize,
    colors: WindowColors
};