const std = @import("std");
const owos = @import("../root.zig");

pub const Window = struct {
    name: [:0]const u8,
    pos_x: u32,
    pos_y: u32,
    width: u32,
    height: u32,

    bg_col: u32,
    title_col: u32,
    titlebar_col: u32,
    border_col: u32,
    border_size: u8,
    has_border: bool,
    inner_shadow: bool,
    shadow_size: u8,

    pub fn init(name: [:0]const u8) Window {
        return Window{
            .name = name,
            .pos_x = 800,
            .pos_y = 200,
            .width = 400,
            .height = 300,

            .bg_col = 0x202020,
            .title_col = 0xAAAAAA,
            .titlebar_col = 0x2F2F2F,
            .border_col = 0x2F2F2F,
            .border_size = 1,
            .has_border = true,
            .inner_shadow = true,
            .shadow_size = 10,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn once(self: *Window) void {
        _ = self;
    }

    pub fn tick(self: Window) u8 {
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, self.height, self.bg_col);
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, 20, self.titlebar_col);

        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.border_size, self.height, self.border_col); // left
        owos.c.draw_rect_f(self.pos_x, self.pos_y + self.height, self.width, self.border_size, self.border_col); // bottom
        owos.c.draw_rect_f(self.pos_x + self.width - self.border_size, self.pos_y, self.border_size, self.height, self.border_col); // right
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, self.border_size, self.border_col); // top

        owos.c.draw_text(self.pos_x + (self.width / 2) - (@as(u32, @intCast(self.name.len)) * 8 / 2), self.pos_y + 2, @ptrCast(self.name.ptr), self.title_col, false, &owos.c.OwOSFont_8x16);

        return 2;
    }
};
