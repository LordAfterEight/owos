const owos = @import("../root.zig");
const limine = @import("../limine.zig");

export var fb_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

/// Global framebuffer
pub var GFB: *limine.Framebuffer = undefined;

pub var GFB_WIDTH: u64 = undefined;
pub var GFB_HEIGHT: u64 = undefined;

/// Flag that allows checking whether the global framebuffer exists
pub var GFB_VALID: bool = false;

/// Initializes the global framebuffer
/// On failure the global framebuffer validity flag will remain false, but the OS won't panic.
pub fn init_fb() !void {
    owos.serial.writeln("Getting limine framebuffer request...");
    const fb = fb_request.response orelse return error.NoFramebuffer;
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

pub fn print(x: usize, y: usize, msg: []const u8) void {
    var x_offset: usize = 0;
    var y_offset: usize = 0;
    for (msg) |c| {
        const glyph = owos.fb.font.get_glyph(c);
        for (glyph) |row| {
            for (0..8) |pixel| {
                if ((row >> @as(u3, @truncate(8 - pixel))) & 1 != 0) {
                    blit_pixel(x + x_offset + pixel, y + y_offset, 0xFFFFFF);
                }
            }
            y_offset += 1;
        }
        x_offset += 8;
        y_offset = 0;
    }
}
