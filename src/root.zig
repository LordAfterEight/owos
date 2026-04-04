/// Serial port printing tools
pub const serial = @import("serial/serial.zig");
/// Framebuffer rendering tools
pub const fb = struct {
    pub const rendering = @import("rendering/rendering.zig");
    pub const font = @import("font/font.zig");
};
