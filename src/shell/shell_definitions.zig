const std = @import("std");
const owos = @import("../root.zig");
const build_options = @import("build_options");

pub const InputBuffer = struct {
    tokens: [16][128]u8,
    token_counter: u8,
    char_counter: u8,

    pub fn push(self: *InputBuffer, val: u8) void {
        if (val == ' ') self.token += 1;
        self.tokens[self.token][self.char_counter] = val;
        self.char_counter += 1;
    }
};

pub const Cursor = struct {
};


pub const Shell = struct {
    name: [:0]const u8,
    window: owos.ui.window.Window,

    pub fn init(name: [:0]const u8) Shell {
        return Shell {
            .name = name,
            .window = owos.ui.window.Window.init(name),
        };
    }

    pub fn once(self: *Shell) void {
        self.window.width = 800;
        self.window.height = 500;
        self.window.draw_text(0, 0, "Hello World from Shelly!", 0xFFFFFF);
        self.window.draw_text(0, 16, "Hello World from Shelly!", 0xFFFFFF);
        self.window.draw_text(0, 32, "Hello World from Shelly!", 0xFFFFFF);
        if (owos.ui.owm.owm_global) |owm| {
            owm.add_window(&self.window);
        }
    }

    pub fn deinit(self: *Shell) void {_ = self;}

    pub fn tick(self: *Shell) anyerror!u8 {
        _ = self;
        return 2;
    }
};
