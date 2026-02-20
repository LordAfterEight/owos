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
    char: u8 = 0,
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
        return DrawCall{
            .type = call_type,
            .values = values,
        };
    }
};

pub const Window = struct {
    name: [:0]const u8,
    draw_queue: [4096]?DrawCall,
    draw_queue_counter: u16,
    pos_x: u32,
    pos_y: u32,
    width: u32,
    height: u32,
    framebuffer: []u32,

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

    pub fn init(name: [:0]const u8, w: u32, h: u32) Window {
        return Window{
            .name = name,
            .draw_queue = [_]?DrawCall{null} ** 4096,
            .draw_queue_counter = 0,
            .pos_x = 200,
            .pos_y = 200,
            .width = w,
            .height = h,
            .framebuffer = owos.allocator.global_alloc.alloc(u32, w * h) catch unreachable,

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
        self.draw_rect_f_inner(self.border_size + 1, 27, self.width - self.border_size - 1, self.height - 27, self.bg_col); // Inner fill
        self.draw_rect_f_inner(self.border_size, 26, 1, self.height - self.border_size - 26, self.dark_edge_color); // Inner shadow left
        self.draw_rect_f_inner(self.border_size, 26, self.width - self.border_size, 1, self.dark_edge_color); // Inner shadow top

        self.draw_rect_f_inner(0, 0, self.width, 26, self.titlebar_col); // titlebar

        self.draw_rect_f_inner(0, 0, self.border_size, self.height, self.border_col); // left border
        self.draw_rect_f_inner(0, self.height - self.border_size, self.width, self.border_size, self.border_col); // bottom border
        self.draw_rect_f_inner(self.width - self.border_size, 0, self.border_size, self.height, self.border_col); // right border
        self.draw_rect_f_inner(0, 0, self.width, self.border_size, self.border_col); // top border

        self.draw_rect_f_inner(0, 0, 1, self.height, self.light_edge_color); // left border chamfer
        self.draw_rect_f_inner(0, 0, self.width, 1, self.light_edge_color); // top border chamfer
        self.draw_rect_f_inner(self.border_size, self.height - self.border_size, self.width - self.border_size * 2, 1, self.light_edge_color); // bottom border inner chamfer
        self.draw_rect_f_inner(self.width - self.border_size, 26, 1, self.height - 25 - self.border_size, self.light_edge_color); // left border inner chamfer

        self.draw_rect_f_inner(self.border_size, 3, self.width - self.border_size * 2, 20, self.dark_edge_color); // inner titlebar shadow
        self.draw_rect_f_inner(self.border_size + 1, 4, self.width - self.border_size * 2 - 2, 18, self.titlebar_inner_col); // inner titlebar

        self.draw_title(); // title

        for (0..self.draw_queue_counter) |i| {
            if (self.draw_queue[i]) |call| {
                switch (call.type) {
                    DrawCallType.DrawRectF => self.draw_rect_f_inner(call.values.x, call.values.y, call.values.w, call.values.h, call.values.color),
                    DrawCallType.DrawText => self.draw_text_inner(call.values.x, call.values.y, call.values.text, call.values.color, &owos.c.OwOSFont_8x16),
                    DrawCallType.DrawChar => self.draw_char_inner(call.values.x, call.values.y, call.values.char, call.values.color, &owos.c.OwOSFont_8x16),
                    else => continue,
                }
            }
        }

        self.draw_queue = [_]?DrawCall{null} ** 4096;
        self.draw_queue_counter = 0;
    }

    pub fn tick(self: *Window) anyerror!u8 {
        if (self.dirty) {
            self.redraw();
            self.dirty = false;
        }
        return 2;
    }

    pub fn refresh(self: *Window) void {
        self.dirty = true;
    }

    pub fn draw_title(self: *Window) void {
        var char_offset: u8 = 0;
        for (self.name) |char| {
            const bitmap = owos.c.get_bitmap(char, &owos.c.OwOSFont_8x16);
            for (0..owos.c.OwOSFont_8x16.height) |char_y| {
                for (0..owos.c.OwOSFont_8x16.width) |char_x| {
                    const pixel_on = (bitmap[char_y] & (@as(usize, @intCast(0x80)) >> @as(u6, @intCast(char_x)))) != 0;
                    if (pixel_on) {
                        self.put_pixel(self.border_size + (self.width / 2) - (@as(u32, @intCast(self.name.len)) * 8 / 2) + @as(u32, @intCast(char_x + char_offset)), 6 + @as(u32, @intCast(char_y)), self.title_col);
                    }
                }
            }
            char_offset += owos.c.OwOSFont_8x16.width;
        }
    }

    pub fn draw_text(self: *Window, x: u32, y: u32, text: [:0]const u8, color: u32) void {
        if (self.draw_queue_counter < self.draw_queue.len) {
            self.draw_queue[self.draw_queue_counter] = DrawCall.new(DrawCallType.DrawText, DrawValues{ .x = x, .y = y, .text = text, .color = color });
            self.draw_queue_counter += 1;
        }
    }

    pub fn draw_char(self: *Window, x: u32, y: u32, char: u8, color: u32) void {
        if (self.draw_queue_counter < self.draw_queue.len) {
            self.draw_queue[self.draw_queue_counter] = DrawCall.new(DrawCallType.DrawChar, DrawValues{ .x = x, .y = y, .char = char, .color = color });
            self.draw_queue_counter += 1;
        }
    }

    fn put_pixel(self: *Window, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.framebuffer[y * self.width + x] = color;
    }

    fn draw_rect_f_inner(self: *Window, x: u32, y: u32, width: u32, height: u32, color: u32) void {
        for (0..height) |y_p| {
            for (0..width) |x_p| {
                self.put_pixel(x + @as(u32, @intCast(x_p)), y + @as(u32, @intCast(y_p)), color);
            }
        }
    }
    fn draw_text_inner(self: *Window, x: u32, y: u32, text: [:0]const u8, color: u32, font: *owos.c.Font) void {
        var char_offset: u8 = 0;
        for (text) |char| {
            const bitmap = owos.c.get_bitmap(char, font);
            for (0..font.height) |char_y| {
                for (0..font.width) |char_x| {
                    const pixel_on = (bitmap[char_y] & (@as(usize, @intCast(0x80)) >> @as(u6, @intCast(char_x)))) != 0;
                    if (pixel_on) {
                        self.put_pixel(self.border_size + 1 + x + @as(u32, @intCast(char_x + char_offset)), 11 + y + @as(u32, @intCast(char_y)), color);
                    }
                }
            }
            char_offset += font.width;
        }
    }
    fn draw_char_inner(self: *Window, x: u32, y: u32, text: u8, color: u32, font: *owos.c.Font) void {
        const bitmap = owos.c.get_bitmap(text, font);
        for (0..font.height) |char_y| {
            for (0..font.width) |char_x| {
                const pixel_on = (bitmap[char_y] & (@as(usize, @intCast(0x80)) >> @as(u6, @intCast(char_x)))) != 0;
                if (pixel_on) {
                    self.put_pixel(self.border_size + 1 + x + @as(u32, @intCast(char_x)), 11 + y + @as(u32, @intCast(char_y)), color);
                }
            }
        }
    }
};
