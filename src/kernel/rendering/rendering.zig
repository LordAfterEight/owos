const std = @import("std");
const owos = @import("../root.zig");
const limine = @import("limine");

export var fb_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

/// Desired size of the on-screen log window in characters.
/// Change these to resize the logging area without touching anything else.
pub const LOG_COLS: usize = 180;
pub const LOG_ROWS: usize = 67;

/// Global framebuffer
pub var GFB: *limine.Framebuffer = undefined;

pub var GFB_WIDTH: u64 = undefined;
pub var GFB_HEIGHT: u64 = undefined;

/// Flag that allows checking whether the global framebuffer exists
pub var GFB_VALID: bool = false;

/// Virtual base address for the back buffer (must not collide with HHDM or RAMFS).
const BACKBUF_BASE: u64 = 0xffffa00000000000;

/// Back buffer – null until init_back_buffer() succeeds.
var back_buffer: ?[*]u8 = null;
var back_buffer_size: usize = 0;

/// Returns the render target: back buffer if available, otherwise the real framebuffer.
fn target() [*]u8 {
    return back_buffer orelse GFB.address;
}

/// Allocates pages for the back buffer and copies the current framebuffer into it.
/// Must be called after PMM and VMM are initialised.
pub fn init_back_buffer() void {
    if (!GFB_VALID) return;
    const size: usize = @intCast(GFB.height * GFB.pitch);
    const pages = (size + 4095) / 4096;
    const alloc_size: u64 = @as(u64, pages) * 4096;

    owos.vmm.map_range(BACKBUF_BASE, alloc_size, owos.vmm.Flags.WRITE | owos.vmm.Flags.NX);

    back_buffer = @ptrFromInt(BACKBUF_BASE);
    back_buffer_size = size;

    // Snapshot whatever is currently on screen so the first swap() is correct.
    @memcpy(back_buffer.?[0..size], GFB.address[0..size]);

    owos.klog.info("FB: back buffer at {x:0>16}  ({d} pages)", .{ BACKBUF_BASE, pages });
}

/// When true, swap() draws a "[LOCKDOWN]" indicator in the upper-right corner
/// of the front buffer after every blit.
pub var lockdown_overlay: bool = false;

/// Copies the back buffer to the real framebuffer.  No-op before init_back_buffer().
pub fn swap() void {
    const bb = back_buffer orelse return;
    @memcpy(GFB.address[0..back_buffer_size], bb[0..back_buffer_size]);
    if (lockdown_overlay) draw_lockdown_badge();
}

/// Draws "[LOCKDOWN]" in pure red at the top-right corner, directly onto the
/// front buffer so it is always visible and cannot be overwritten by the log.
fn draw_lockdown_badge() void {
    const label = "[LOCKDOWN]";
    const label_w = label.len * 8; // 8 px per glyph
    const padding = 6;
    const badge_w = label_w + padding * 2;
    const badge_h = 16 + padding * 2;
    const x = @as(usize, @intCast(GFB_WIDTH)) -| (badge_w + 4);
    const y: usize = 4;
    const fb = GFB.address;
    const bpp = GFB.bpp / 8;

    // Draw dark red background box
    const bg: u32 = 0x200000;
    for (0..badge_h) |dy| {
        for (0..badge_w) |dx| {
            const px = x + dx;
            const py = y + dy;
            if (px < GFB_WIDTH and py < GFB_HEIGHT) {
                const off = py * GFB.pitch + px * bpp;
                for (0..bpp) |b| {
                    fb[off + b] = @truncate(bg >> (@as(u5, @truncate(b)) * 8));
                }
            }
        }
    }

    // Draw glyphs directly onto the front buffer
    const color: u32 = @intFromEnum(Color.PureRed);
    const tx = x + padding;
    const ty = y + padding;
    for (label, 0..) |c, ci| {
        const glyph = owos.fb.font.get_glyph(c);
        for (glyph, 0..) |row, gy| {
            for (0..8) |px_bit| {
                if ((row >> @as(u3, @truncate(7 - px_bit))) & 1 != 0) {
                    const px = tx + ci * 8 + px_bit;
                    const py = ty + gy;
                    if (px < GFB_WIDTH and py < GFB_HEIGHT) {
                        const off = py * GFB.pitch + px * bpp;
                        for (0..bpp) |b| {
                            fb[off + b] = @truncate(color >> (@as(u5, @truncate(b)) * 8));
                        }
                    }
                }
            }
        }
    }
}


pub const Color = enum(u32) {
    Black = 0x000000,
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

    PureRed = 0xFF0000,

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
    ScrollingLog.instance.rows = @min(avail_h / ScrollingLog.char_height, LOG_ROWS);
    ScrollingLog.instance.cols = @min(GFB_WIDTH / ScrollingLog.char_width, LOG_COLS);

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
    const buf = target();
    const bpp = GFB.bpp / 8;
    const first_row_off = y * GFB.pitch + x * bpp;
    for (0..w) |i| {
        const off = first_row_off + i * bpp;
        for (0..bpp) |b| {
            buf[off + b] = @truncate(color >> (@as(u5, @truncate(b)) * 8));
        }
    }
    const row_len = w * bpp;
    for (1..h) |dy| {
        const dst_off = (y + dy) * GFB.pitch + x * bpp;
        @memcpy(buf[dst_off .. dst_off + row_len], buf[first_row_off .. first_row_off + row_len]);
    }
}

pub fn blit_pixel(x: usize, y: usize, color: u32) void {
    if (GFB_VALID and x < GFB_WIDTH and y < GFB_HEIGHT) {
        const buf = target();
        const bytes_per_pixel = GFB.bpp / 8;
        const offset = y * GFB.pitch + x * bytes_per_pixel;
        for (0..bytes_per_pixel) |byte| {
            buf[offset + byte] = @as(u8, @truncate((color >> (@as(u5, @truncate(byte)) * 8)) & 0xFF));
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
    print_buf:  [max_cols]u8              = [_]u8{0} ** max_cols,

    // Scrollback ring buffer
    scroll_offset: usize = 0, // 0 = viewing live, >0 = lines scrolled back
    scrollback_count: usize = 0, // how many lines are stored in scrollback
    scrollback_head: usize = 0, // next write position in ring buffer

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

    const scrollback_lines: usize = 512;
    var sb_text:   [scrollback_lines][max_cols]u8    = [_][max_cols]u8{[_]u8{0} ** max_cols} ** scrollback_lines;
    var sb_colors: [scrollback_lines][max_cols]Color  = [_][max_cols]Color{[_]Color{.White} ** max_cols} ** scrollback_lines;
    var sb_len:    [scrollback_lines]usize            = [_]usize{0} ** scrollback_lines;

    pub fn clear(self: *ScrollingLog) void {
        for (0..self.rows) |row| {
            self.text_len[row] = 0;
            self.clearFullRow(row);
        }
        self.y_pos = 0;
        self.x_pos = 0;
        self.scroll_offset = 0;
        self.scrollback_count = 0;
        self.scrollback_head = 0;
    }

    pub fn newline(self: *ScrollingLog) void {
        owos.serial.write_byte('\n');
        self.x_pos = 0;
        self.y_pos += 1;
    }

    pub fn print(self: *ScrollingLog, comptime fmt: []const u8, args: anytype, color: Color) void {
        const msg = std.fmt.bufPrint(&self.print_buf, fmt, args) catch self.print_buf[0..];
        owos.serial.write(msg);

        // Scroll if a previous newline pushed us past the last row.
        if (self.y_pos >= self.rows) {
            // Save the top line to scrollback before shifting
            const head = self.scrollback_head;
            @memcpy(&sb_text[head], &self.text[0]);
            @memcpy(&sb_colors[head], &self.text_colors[0]);
            sb_len[head] = self.text_len[0];
            self.scrollback_head = (head + 1) % scrollback_lines;
            if (self.scrollback_count < scrollback_lines) self.scrollback_count += 1;

            // If we're scrolled back, track that the view shifted
            if (self.scroll_offset > 0) self.scroll_offset += 1;

            // Shift text data.
            for (0..self.rows - 1) |row| {
                @memcpy(&self.text[row], &self.text[row + 1]);
                @memcpy(&self.text_colors[row], &self.text_colors[row + 1]);
                self.text_len[row] = self.text_len[row + 1];
            }
            self.text_len[self.rows - 1] = 0;
            self.y_pos = self.rows - 1;
            self.x_pos = 0;
            // Redraw every row from the text buffers.  This is write-only —
            // reading from an MMIO framebuffer (the old pixel-shift approach)
            // is orders of magnitude slower on real hardware.
            // Interleaving clear+draw per row keeps flicker to a minimum.
            if (GFB_VALID) {
                for (0..self.rows) |row| {
                    self.clearFullRow(row);
                    self.drawRow(row);
                }
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

    pub fn backspace(self: *ScrollingLog) void {
        if (self.x_pos > 0) {
            // Erase the character cell being removed before shrinking text_len,
            // otherwise clearRow won't reach it.
            const col = self.x_pos - 1;
            const px = 2 + col * char_width;
            const y = self.y_offset + self.y_pos * char_height;
            if (GFB_VALID) {
                const buf = target();
                const bpp = GFB.bpp / 8;
                for (0..char_height) |dy| {
                    const off = (y + dy) * GFB.pitch + px * bpp;
                    @memset(buf[off .. off + char_width * bpp], 0);
                }
            }
            self.x_pos = col;
            self.text[self.y_pos][col] = 0;
            self.text_len[self.y_pos] = col;
        }
    }

    pub fn scroll_up(self: *ScrollingLog) void {
        if (self.scroll_offset >= self.scrollback_count) return;
        self.scroll_offset += 1;
        self.redraw_scrolled();
        swap();
    }

    pub fn scroll_down(self: *ScrollingLog) void {
        if (self.scroll_offset == 0) return;
        self.scroll_offset -= 1;
        self.redraw_scrolled();
        swap();
    }

    pub fn redraw_scrolled(self: *ScrollingLog) void {
        if (!GFB_VALID) return;

        if (self.scroll_offset == 0) {
            // Back to live view — redraw from text buffers
            for (0..self.rows) |row| {
                self.clearFullRow(row);
                self.drawRow(row);
            }
            return;
        }

        // How many visible rows come from scrollback vs live text.
        // scroll_offset lines of scrollback replace the bottom N live rows,
        // pushing the live view upward — so scrollback lines appear at top.
        const sb_rows = @min(self.scroll_offset, self.rows);

        for (0..self.rows) |row| {
            self.clearFullRow(row);

            if (row < sb_rows) {
                // Scrollback line. Row 0 = oldest visible, row sb_rows-1 = newest.
                // The newest scrollback line is at (head - 1), we want offset lines back.
                // Row 0 gets the line (offset) positions back from head.
                // Row sb_rows-1 gets the line (offset - sb_rows + 1) positions back.
                const age = self.scroll_offset - row;
                const ring_idx = (self.scrollback_head + scrollback_lines - age) % scrollback_lines;
                const len = sb_len[ring_idx];
                if (len > 0) {
                    const y = self.y_offset + row * char_height;
                    var i: usize = 0;
                    while (i < len) {
                        const run_color = sb_colors[ring_idx][i];
                        var j = i + 1;
                        while (j < len and sb_colors[ring_idx][j] == run_color) j += 1;
                        draw_text(2 + i * char_width, y, sb_text[ring_idx][i..j], @intFromEnum(run_color));
                        i = j;
                    }
                }
            } else {
                // Live text buffer row
                const live_row = row - sb_rows;
                const len = self.text_len[live_row];
                if (len > 0) {
                    const y = self.y_offset + row * char_height;
                    var i: usize = 0;
                    while (i < len) {
                        const run_color = self.text_colors[live_row][i];
                        var j = i + 1;
                        while (j < len and self.text_colors[live_row][j] == run_color) j += 1;
                        draw_text(2 + i * char_width, y, self.text[live_row][i..j], @intFromEnum(run_color));
                        i = j;
                    }
                }
            }
        }
    }

    pub fn println(self: *ScrollingLog, comptime fmt: []const u8, args: anytype, color: Color) void {
        self.print(fmt, args, color);
        self.newline();
        swap();
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
        const buf = target();
        const bpp = GFB.bpp / 8;
        // Cap at GFB.pitch to prevent writing past the end of a scan line,
        // which would page-fault on page-aligned framebuffers (e.g. 1024x768).
        const row_bytes = @min((2 + self.text_len[row] * char_width) * bpp, GFB.pitch);
        const y = self.y_offset + row * char_height;
        for (0..char_height) |dy| {
            const off = (y + dy) * GFB.pitch;
            @memset(buf[off .. off + row_bytes], 0);
        }
    }

    /// Clears the full column width of a row.  Used during scroll where the
    /// old (pre-shift) content may have been wider than the new text_len.
    fn clearFullRow(self: *const ScrollingLog, row: usize) void {
        if (!GFB_VALID) return;
        const buf = target();
        const bpp = GFB.bpp / 8;
        const row_bytes = @min((2 + self.cols * char_width) * bpp, GFB.pitch);
        const y = self.y_offset + row * char_height;
        for (0..char_height) |dy| {
            const off = (y + dy) * GFB.pitch;
            @memset(buf[off .. off + row_bytes], 0);
        }
    }
};
