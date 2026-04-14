/// Serial port printing tools
pub const serial = @import("serial/serial.zig");
/// Kernel log: writes to both serial and screen
pub const klog = @import("klog.zig");
/// Framebuffer rendering tools
pub const fb = struct {
    pub const rendering = @import("rendering/rendering.zig");
    pub const font = @import("font/font.zig");
};
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const idt_tests = @import("idt_tests.zig");
pub const pmm = @import("pmm/pmm.zig");
pub const vmm = @import("vmm/vmm.zig");
pub const ramfs = @import("ramfs/ramfs.zig");
