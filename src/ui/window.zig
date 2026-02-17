const std = @import("std");
const owos = @import("../root.zig");

pub const DrawCall = enum {
    DrawRectF,
    DrawRect,
    DrawText,
};

pub var y_back: bool = false;
pub var x_back: bool = false;

pub const DrawValues = struct {
    text: [256]u8 = [_]u8{0} ** 256,
    color: u32 = 0x0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Window = struct {
    name: [:0]const u8,
    draw_queue: [64]?DrawCall,
    draw_queue_counter: u8,
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

    values: DrawValues,
    process: *owos.process.Process,

    pub fn init(name: [:0]const u8) Window {
        return Window{
            .name = name,
            .draw_queue = [_]?DrawCall{null} ** 64,
            .draw_queue_counter = 0,
            .pos_x = 200,
            .pos_y = 200,
            .width = 800,
            .height = 500,

            .bg_col = 0x8A8984,
            .title_col = 0xCCCCCC,
            .titlebar_col = 0xB3B1AA,
            .border_col = 0xB3B1AA,
            .border_size = 4,
            .has_border = true,
            .inner_shadow = true,
            .shadow_size = 10,

            .values = DrawValues{},
            .process = undefined,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn once(self: *Window) void {
        self.redraw();
    }

    pub fn redraw(self: *Window) void {

        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + 26, self.width - self.border_size, self.height - 26 - self.border_size, self.bg_col - 0x222222); // Inner shadow

        owos.c.draw_rect_f(self.pos_x + self.border_size + 1, self.pos_y + 27, self.width - self.border_size - 1, self.height - 27, self.bg_col); // Inner fill

        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, 26, self.titlebar_col); // titlebar

        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.border_size, self.height, self.border_col); // left border
        owos.c.draw_rect_f(self.pos_x, self.pos_y + self.height - self.border_size, self.width, self.border_size, self.border_col); // bottom border
        owos.c.draw_rect_f(self.pos_x + self.width - self.border_size, self.pos_y, self.border_size, self.height, self.border_col); // right border
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, self.border_size, self.border_col); // top border

        owos.c.draw_rect_f(self.pos_x, self.pos_y, 1, self.height, self.border_col + 0x171717); // left border chamfer
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, 1, self.border_col + 0x171717); // top border chamfer

        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + 3, self.width - self.border_size * 2, 20, self.titlebar_col - 0x777777); // inner titlebar shadow
        owos.c.draw_rect_f(self.pos_x + self.border_size + 1, self.pos_y + 4, self.width - self.border_size * 2 - 1, 18, self.titlebar_col - 0x555555); // inner titlebar

        owos.c.draw_text(self.pos_x + (self.width / 2) - (@as(u32, @intCast(self.name.len)) * 8 / 2), self.pos_y + 5, @ptrCast(self.name.ptr), self.title_col, false, &owos.c.OwOSFont_8x16); // title
    }

    pub fn tick(self: *Window) anyerror!u8 {
        if (owos.c.ticks % 10 == 0) {
            owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, self.height, 0x000000);
            if (self.pos_y + self.height == owos.c.SCREEN_HEIGHT) y_back = true;
            if (self.pos_y == 0) y_back = false;
            if (self.pos_x + self.width == owos.c.SCREEN_WIDTH) x_back = true;
            if (self.pos_x == 0) x_back = false;
            if (x_back) {
                self.pos_x -= 1;
            } else self.pos_x += 1;
            if (y_back) {
                self.pos_y -= 1;
            } else self.pos_y += 1;
            self.redraw();
        }
        if (self.draw_queue[self.draw_queue_counter] != null) {
            self.redraw();
            for (0..self.draw_queue.len) |call_slot| {
                const call_option = self.draw_queue[call_slot];
                if (call_option != null) {
                    const call = call_option.?;
                    switch (call) {
                        DrawCall.DrawRectF => self.draw_rect_f(self.values.x, self.values.y, self.values.w, self.values.h, self.values.color),
                        else => continue,
                    }
                    self.draw_queue[call_slot] = null;
                    self.draw_queue_counter -= 1;
                }
            }
        }

        return 2;
    }

    pub fn draw_rect_f(self: *Window, x: u32, y: u32, width: u32, height: u32, color: u32) void {
        if (x > self.pos_x and x < self.pos_x + self.width and
            y > self.pos_y and y < self.pos_y + self.height and
            x + width < self.pos_x + self.width and
            y + height < self.pos_y + self.height)
        {
            owos.c.draw_rect_f(x, y, width, height, color);
        }
    }
};
