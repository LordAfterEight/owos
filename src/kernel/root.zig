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
pub const ps2 = @import("drivers/ps2.zig");
pub const rdrand = @import("rdrand.zig");
pub const acpi = @import("drivers/acpi.zig");
pub const pci = @import("drivers/pci.zig");
pub const e1000 = @import("drivers/e1000.zig");
pub const xhci = @import("drivers/xhci.zig");
pub const ahci = @import("drivers/ahci.zig");
pub const usb_storage = @import("drivers/usb_storage.zig");
pub const net = @import("net.zig");
pub const fat32 = @import("fat32.zig");
pub const shell = @import("shell.zig");
pub const editor = @import("editor.zig");
