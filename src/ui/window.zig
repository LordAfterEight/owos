const std = @import("std");
const owos = @import("../root.zig");

pub const DrawCallType = enum {
    DrawRectF,
    DrawRect,
    DrawText,
    DrawChar,
};

pub const DrawValues = struct {
    text: [:0]const u8 = undefined,
    color: u32 = 0x0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const DrawCall = struct {
    type: DrawCallType,
    values: DrawValues,

    fn new(call_type: DrawCallType, values: DrawValues) DrawCall {
        return DrawCall {
            .type = call_type,
            .values = values,
        };
    }
};

pub const Window = struct {
    name: [:0]const u8,
    draw_queue: [512]?DrawCall,
    draw_queue_counter: u8,
    pos_x: u32,
    pos_y: u32,
    width: u32,
    height: u32,
    framebuffer: [1280 * 720]u32,

    bg_col: u32,
    title_col: u32,
    titlebar_col: u32,
    titlebar_inner_col: u32,
    border_col: u32,
    border_size: u8,
    has_border: bool,
    inner_shadow: bool,
    shadow_size: u8,
    light_edge_color: u32,
    dark_edge_color: u32,

    process: *owos.process.Process,
    last_render_tick: u32,
    ticks_per_frame: u32,
    dirty: bool,

    pub fn init(name: [:0]const u8) Window {
        return Window{
            .name = name,
            .draw_queue = [_]?DrawCall{null} ** 512,
            .draw_queue_counter = 0,
            .pos_x = 200,
            .pos_y = 200,
            .width = 800,
            .height = 500,

            .bg_col = 0x8A8984,
            .title_col = 0xCCCCCC,
            .titlebar_col = 0xB3B1AA,
            .titlebar_inner_col = 0x474747,
            .border_col = 0xB3B1AA,
            .border_size = 4,
            .has_border = true,
            .inner_shadow = true,
            .shadow_size = 5,
            .light_edge_color = 0xBBBBBB,
            .dark_edge_color = 0x444444,
            .framebuffer = [_]u32{0} ** (1280 * 720),

            .process = undefined,
            .last_render_tick = 0,
            .ticks_per_frame = 16,
            .dirty = true,
        };
    }

    pub fn deinit(self: *Window) void {
        _ = self;
    }

    pub fn once(self: *Window) void {
        self.redraw();
    }

    pub fn redraw(self: *Window) void {

        owos.c.draw_rect_f(self.pos_x + self.border_size + 1, self.pos_y + 27, self.width - self.border_size - 1, self.height - 27, self.bg_col); // Inner fill
        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + 26, 1, self.height - self.border_size - 26, self.dark_edge_color); // Inner shadow left
        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + 26, self.width - self.border_size, 1, self.dark_edge_color); // Inner shadow top

        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, 26, self.titlebar_col); // titlebar

        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.border_size, self.height, self.border_col); // left border
        owos.c.draw_rect_f(self.pos_x, self.pos_y + self.height - self.border_size, self.width, self.border_size, self.border_col); // bottom border
        owos.c.draw_rect_f(self.pos_x + self.width - self.border_size, self.pos_y, self.border_size, self.height, self.border_col); // right border
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, self.border_size, self.border_col); // top border


        owos.c.draw_rect_f(self.pos_x, self.pos_y, 1, self.height, self.light_edge_color); // left border chamfer
        owos.c.draw_rect_f(self.pos_x, self.pos_y, self.width, 1, self.light_edge_color); // top border chamfer
        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + self.height - self.border_size, self.width - self.border_size * 2, 1, self.light_edge_color); // bottom border inner chamfer
        owos.c.draw_rect_f(self.pos_x + self.width - self.border_size, self.pos_y + 26, 1, self.height - 25 - self.border_size, self.light_edge_color); // left border inner chamfer

        owos.c.draw_rect_f(self.pos_x + self.border_size, self.pos_y + 3, self.width - self.border_size * 2, 20, self.dark_edge_color); // inner titlebar shadow
        owos.c.draw_rect_f(self.pos_x + self.border_size + 1, self.pos_y + 4, self.width - self.border_size * 2 - 2, 18, self.titlebar_inner_col); // inner titlebar

        owos.c.draw_text(self.pos_x + (self.width / 2) - (@as(u32, @intCast(self.name.len)) * 8 / 2), self.pos_y + 5, @ptrCast(self.name.ptr), self.title_col, false, &owos.c.OwOSFont_8x16); // title

        for (0..self.draw_queue_counter) |i| {
            if (self.draw_queue[i]) |call| {
                switch (call.type) {
                    DrawCallType.DrawRectF => self.draw_rect_f_inner(call.values.x, call.values.y, call.values.w, call.values.h, call.values.color),
                    DrawCallType.DrawText => self.draw_text_inner(call.values.x, call.values.y, call.values.text, call.values.color, &owos.c.OwOSFont_8x16),
                    DrawCallType.DrawChar => self.draw_char_inner(call.values.x, call.values.y, call.values.text[1], call.values.color, &owos.c.OwOSFont_8x16),
                    else => continue,
                }
            }
        }

        self.draw_queue = [_]?DrawCall{null} ** 512;
        self.draw_queue_counter = 0;
    }

    pub fn tick(self: *Window) anyerror!u8 {
        _ = self;
        return 2;
    }

    pub fn refresh(self: *Window) void {
        self.dirty = true;
    }

    pub fn draw_text(self: *Window, x: u32, y: u32, text: [:0]const u8, color: u32) void {
        if (self.draw_queue_counter < self.draw_queue.len) {
            self.draw_queue[self.draw_queue_counter] = DrawCall.new(
                DrawCallType.DrawText,
                DrawValues{
                    .x = x,
                    .y = y,
                    .text = text,
                    .color = color
                }
            );
            self.draw_queue_counter += 1;
        }
    }

    pub fn draw_char(self: *Window, x: u32, y: u32, char: u8, color: u32) void {
        if (self.draw_queue_counter < self.draw_queue.len) {
            self.draw_queue[self.draw_queue_counter] = DrawCall.new(
                DrawCallType.DrawText,
                DrawValues{
                    .x = x,
                    .y = y,
                    .text = &[1:0]u8{char},
                    .color = color
                }
            );
            self.draw_queue_counter += 1;
        }
    }

    fn draw_rect_f_inner(self: *Window, x: u32, y: u32, width: u32, height: u32, color: u32) void {
        if (x > self.pos_x and x < self.pos_x + self.width and
            y > self.pos_y and y < self.pos_y + self.height and
            x + width < self.pos_x + self.width and
            y + height < self.pos_y + self.height
        ) {
            owos.c.draw_rect_f(x, y, width, height, color);
        }
    }
    fn draw_text_inner(self: *Window, x: u32, y: u32, text: [:0]const u8, color: u32, font: *owos.c.Font) void {
        const abs_x = self.pos_x + self.border_size + 4 + x;
        const abs_y = self.pos_y + 29 + y;
        if (abs_x + (text.len * font.width) < self.pos_x + self.width - self.border_size and
            abs_y + font.height < self.pos_y + self.height - self.border_size
        ) {
            owos.c.draw_text(abs_x, abs_y, text, color, false, font);
        }
    }
    fn draw_char_inner(self: *Window, x: u32, y: u32, text: u8, color: u32, font: *owos.c.Font) void {
        const abs_x = self.pos_x + self.border_size + 4 + x;
        const abs_y = self.pos_y + 29 + y;
        if (abs_x + font.width < self.pos_x + self.width - self.border_size and
            abs_y + font.height < self.pos_y + self.height - self.border_size
        ) {
            owos.c.draw_char(abs_x, abs_y, text, color, false, font);
        }
    }
};
