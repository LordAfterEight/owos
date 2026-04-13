const std = @import("std");
const owos = @import("../root.zig");
const limine = @import("limine");

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

/// Initializes the global framebuffer and sizes ScrollingLog to fit it.
/// On failure the global framebuffer validity flag will remain false, but the OS won't panic.
pub fn init_fb() !void {
    owos.serial.writeln("Getting limine framebuffer request...");
    const response_ptr: *const volatile ?*limine.FramebufferResponse = @ptrCast(&fb_request.response);
    const fb = response_ptr.* orelse return error.NoFramebuffer;
    GFB = fb.framebuffers[0];

    GFB_VALID = true;
    GFB_WIDTH = GFB.width;
    GFB_HEIGHT = GFB.height;

    // Size the scrolling log to the actual framebuffer dimensions.
    const y_off = ScrollingLog.instance.y_offset;
    const avail_h = GFB_HEIGHT -| y_off;
    ScrollingLog.instance.rows = @min(avail_h / ScrollingLog.char_height, ScrollingLog.max_rows);
    ScrollingLog.instance.cols = @min(GFB_WIDTH / ScrollingLog.char_width, ScrollingLog.max_cols);

    owos.serial.write("  FB: addr=");
    owos.serial.write_hex64(@intFromPtr(GFB.address));
    owos.serial.write(" width=");
    owos.serial.write_dec(GFB.width);
    owos.serial.write(" height=");
    owos.serial.write_dec(GFB.height);
    owos.serial.write(" pitch=");
    owos.serial.write_dec(GFB.pitch);
    owos.serial.write(" bpp=");
    owos.serial.write_dec(GFB.bpp);
    owos.serial.writeln("");
    owos.serial.write("  ScrollingLog: rows=");
    owos.serial.write_dec(ScrollingLog.instance.rows);
    owos.serial.write(" cols=");
    owos.serial.write_dec(ScrollingLog.instance.cols);
    owos.serial.writeln("");
    owos.serial.writeln("Framebuffer initialized");
}

pub fn test_fb() void {
    owos.serial.writeln("Testing framebuffer...");

    const w = GFB.width;
    const h = GFB.height;

    // Full-screen HSV gradient: hue sweeps left→right, brightness top→bottom.
    for (0..h) |y| {
        const brightness: u32 = @intCast(255 - (y * 255) / h);
        for (0..w) |x| {
            // Map x to a position in [0, 1536): six 256-step hue segments.
            const pos: u32 = @intCast((x * 1536) / w);
            const seg = pos / 256;
            const t: u32 = pos % 256;

            const r: u32 = switch (seg) {
                0 => 255,
                1 => 255 - t,
                2 => 0,
                3 => 0,
                4 => t,
                else => 255,
            };
            const g: u32 = switch (seg) {
                0 => t,
                1 => 255,
                2 => 255,
                3 => 255 - t,
                else => 0,
            };
            const b: u32 = switch (seg) {
                0 => 0,
                1 => 0,
                2 => t,
                3 => 255,
                4 => 255,
                else => 255 - t,
            };

            blit_pixel(x, y,
                ((r * brightness / 255) << 16) |
                ((g * brightness / 255) << 8)  |
                 (b * brightness / 255));
        }
    }

    owos.serial.writeln("Framebuffer test complete");

    draw_rect(0, 0, owos.fb.rendering.GFB_WIDTH, owos.fb.rendering.GFB_HEIGHT, 0x000000);
}

pub fn draw_rect(x: usize, y: usize, w: usize, h: usize, color: u32) void {
    if (!GFB_VALID or w == 0 or h == 0) return;
    const bpp = GFB.bpp / 8;
    const first_row_off = y * GFB.pitch + x * bpp;
    for (0..w) |i| {
        const off = first_row_off + i * bpp;
        for (0..bpp) |b| {
            GFB.address[off + b] = @truncate(color >> (@as(u5, @truncate(b)) * 8));
        }
    }
    const row_len = w * bpp;
    for (1..h) |dy| {
        const dst_off = (y + dy) * GFB.pitch + x * bpp;
        @memcpy(GFB.address[dst_off .. dst_off + row_len], GFB.address[first_row_off .. first_row_off + row_len]);
    }
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
    x_pos: usize = 0,
    /// Pixel offset from the top of the framebuffer.  Set before init_fb() is
    /// called to leave a top margin (e.g. for a status bar).
    y_offset: usize = 0,
    /// Actual number of text rows, computed from (GFB_HEIGHT - y_offset) / char_height.
    /// Defaults to a safe value until init_fb() runs.
    rows: usize = 25,
    /// Actual number of text columns, computed from GFB_WIDTH / char_width.
    cols: usize = 180,

    text:       [max_rows][max_cols]u8    = [_][max_cols]u8{[_]u8{0} ** max_cols} ** max_rows,
    text_len:   [max_rows]usize           = [_]usize{0} ** max_rows,
    text_colors:[max_rows][max_cols]Color = [_][max_cols]Color{[_]Color{.White} ** max_cols} ** max_rows,

    pub var instance: ScrollingLog = .{};

    pub fn init() *ScrollingLog {
        instance.y_pos = 0;
        instance.x_pos = 0;
        return &instance;
    }

    pub const char_height: usize = 16;
    pub const char_width:  usize = 8;
    /// Hard upper bounds for static buffer allocation.
    /// Covers up to 4096 px tall / 16 px per row = 256 rows,
    /// and up to 3840 px wide / 8 px per col = 480 cols.
    pub const max_rows: usize = 256;
    pub const max_cols: usize = 480;

    pub fn newline(self: *ScrollingLog) void {
        owos.serial.write_byte('\n');
        self.x_pos = 0;
        self.y_pos += 1;
    }

    pub fn print(self: *ScrollingLog, comptime fmt: []const u8, args: anytype, color: Color) void {
        var msgbuf: [max_cols]u8 = undefined;
        const msg = std.fmt.bufPrint(&msgbuf, fmt, args) catch msgbuf[0..];
        owos.serial.write(msg);

        // Scroll if a previous newline pushed us past the last row.
        if (self.y_pos >= self.rows) {
            for (0..self.rows - 1) |row| {
                @memcpy(&self.text[row], &self.text[row + 1]);
                @memcpy(&self.text_colors[row], &self.text_colors[row + 1]);
                self.text_len[row] = self.text_len[row + 1];
            }
            self.text_len[self.rows - 1] = 0;
            self.y_pos = self.rows - 1;
            self.x_pos = 0;
            for (0..self.rows) |row| {
                self.clearRow(row);
                self.drawRow(row);
            }
        }

        // Append at the current column position.
        const available = self.cols - self.x_pos;
        const len = @min(msg.len, available);
        const start = self.x_pos;
        @memcpy(self.text[self.y_pos][start .. start + len], msg[0..len]);
        @memset(self.text_colors[self.y_pos][start .. start + len], color);
        self.x_pos += len;
        if (self.x_pos > self.text_len[self.y_pos]) self.text_len[self.y_pos] = self.x_pos;

        self.clearRow(self.y_pos);
        self.drawRow(self.y_pos);
    }

    pub fn println(self: *ScrollingLog, comptime fmt: []const u8, args: anytype, color: Color) void {
        self.print(fmt, args, color);
        self.newline();
    }

    fn drawRow(self: *const ScrollingLog, row: usize) void {
        const len = self.text_len[row];
        if (len == 0) return;
        const y = self.y_offset + row * char_height;
        var i: usize = 0;
        while (i < len) {
            const run_color = self.text_colors[row][i];
            var j = i + 1;
            while (j < len and self.text_colors[row][j] == run_color) j += 1;
            draw_text(2 + i * char_width, y, self.text[row][i..j], @intFromEnum(run_color));
            i = j;
        }
    }

    fn clearRow(self: *const ScrollingLog, row: usize) void {
        if (!GFB_VALID) return;
        const bpp = GFB.bpp / 8;
        const row_bytes = (2 + self.text_len[row] * char_width) * bpp;
        const y = self.y_offset + row * char_height;
        for (0..char_height) |dy| {
            const off = (y + dy) * GFB.pitch;
            @memset(GFB.address[off .. off + row_bytes], 0);
        }
    }
};
