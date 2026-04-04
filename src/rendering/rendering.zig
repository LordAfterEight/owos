const owos = @import("../root.zig");
const limine = @import("../limine.zig");

export var fb_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

/// Global framebuffer
pub var GFB: *limine.Framebuffer = undefined;

pub var GFB_WIDTH: u64 = undefined;
pub var GFB_HEIGHT: u64 = undefined;

/// Flag that allows checking whether the global framebuffer exists
pub var GFB_VALID: bool = false;


pub const Color = enum(u32) {
    BrightYellow = 0xFFFF77,
    BrightRed = 0xFF7777,
    BrightGreen = 0x77FF77,
    BrightBlue = 0x7777FF,
    BrightMagenta = 0xFF77FF,

    DarkYellow = 0x555533,
    DarkRed = 0x553333,
    DarkGreen = 0x33553,
    DarkBlue = 0x333355,
    DarkMagenta = 0x553355,

    Yellow = 0xFFFF33,
    Red = 0xFF3333,
    Green = 0x33FF33,
    Blue = 0x3333FF,
    Magenta = 0xFF33FF,

    White = 0xFFFFFF,
    BrightGrey = 0xAAAAAA,
    Grey = 0x777777,
    DarkGrey = 0x555555,
};

/// Initializes the global framebuffer
/// On failure the global framebuffer validity flag will remain false, but the OS won't panic.
pub fn init_fb() !void {
    owos.serial.writeln("Getting limine framebuffer request...");
    const response_ptr: *const volatile ?*limine.FramebufferResponse = @ptrCast(&fb_request.response);
    const fb = response_ptr.* orelse return error.NoFramebuffer;
    GFB = fb.framebuffers[0];
    owos.serial.writeln("Success");

    GFB_VALID = true;
}

pub fn test_fb() void {
    owos.serial.writeln("Testing framebuffer...");
    for (0..GFB.width) |x| {
        for (0..GFB.height) |y| {
            blit_pixel(x, y, 0xFF0000);
        }
    }
    owos.serial.writeln("Red done...");
    for (0..GFB.width) |x| {
        for (0..GFB.height) |y| {
            blit_pixel(x, y, 0x00FF00);
        }
    }
    owos.serial.writeln("Green done...");
    for (0..GFB.width) |x| {
        for (0..GFB.height) |y| {
            blit_pixel(x, y, 0x0000FF);
        }
    }
    owos.serial.writeln("Blue done...");
    for (0..GFB.width) |x| {
        for (0..GFB.height) |y| {
            blit_pixel(x, y, 0x000000);
        }
    }
    owos.serial.writeln("Framebuffer test successful");
}

pub fn blit_pixel(x: usize, y: usize, color: u32) void {
    if (GFB_VALID) {
        const bytes_per_pixel = GFB.bpp / 8;
        const offset = y * GFB.pitch + x * bytes_per_pixel;
        for (0..bytes_per_pixel) |byte| {
            GFB.address[offset + byte] = @as(u8, @truncate((color >> (@as(u5, @truncate(byte)) * 8)) & 0xFF));
        }
    }
}

pub fn draw_text(x: usize, y: usize, msg: []const u8, color: u32) void {
    var x_offset: usize = 0;
    var y_offset: usize = 0;
    for (msg) |c| {
        const glyph = owos.fb.font.get_glyph(c);
        for (glyph) |row| {
            for (0..8) |pixel| {
                if ((row >> @as(u3, @truncate(7 - pixel))) & 1 != 0) {
                    blit_pixel(x + x_offset + pixel, y + y_offset, color);
                }
            }
            y_offset += 1;
        }
        x_offset += 8;
        y_offset = 0;
    }
}

pub const ScrollingLog = struct {
    y_pos: usize = 0,
    text: [25][120]u8 = [_][120]u8{[_]u8{0} ** 120} ** 25,

    var instance: ScrollingLog = .{};

    pub fn init() *ScrollingLog {
        instance.y_pos = 0;
        return &instance;
    }

    const char_height = 16;
    const char_width = 8;
    const cols = 120;
    const rows = 25;

    pub fn println(self: *ScrollingLog, msg: []const u8, color: Color) void {
        if (self.y_pos == rows) {
            // Shift text buffer up
            for (0..rows - 1) |row| {
                for (0..cols) |col| {
                    self.text[row][col] = self.text[row + 1][col];
                }
            }
            self.y_pos = rows - 1;
            // Redraw all visible rows
            for (0..rows - 1) |row| {
                self.clearRow(row);
                draw_text(2, row * char_height, &self.text[row], @intFromEnum(color));
            }
        }
        // Write new line into buffer
        const len = @min(msg.len, cols);
        for (0..len) |i| self.text[self.y_pos][i] = msg[i];
        for (len..cols) |i| self.text[self.y_pos][i] = ' ';
        // Draw only the new row
        self.clearRow(self.y_pos);
        draw_text(2, self.y_pos * char_height, &self.text[self.y_pos], @intFromEnum(color));
        self.y_pos += 1;
    }

    fn clearRow(self: *const ScrollingLog, row: usize) void {
        _ = self;
        const y_start = row * char_height;
        for (y_start..y_start + char_height) |y| {
            for (0..cols * char_width) |x| {
                blit_pixel(x, y, 0x000000);
            }
        }
    }
};
