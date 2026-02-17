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


pub const Shell = struct {
};
