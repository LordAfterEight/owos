const owos = @import("../root.zig");

pub var owm_global: ?*WindowManager = null;

pub const WindowManager = struct {
    name: [:0]const u8,
    windows: [16]?*owos.ui.window.Window,

    pub fn init(stub: [:0]const u8) WindowManager {
        _ = stub;
        return WindowManager {
            .name = "OwOS Window Manager",
            .windows = .{null} ** 16,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        _ = self;
    }

    pub fn once(self: *WindowManager) void {
        owm_global = self;
    }

    pub fn add_window(self: *WindowManager, window: *owos.ui.window.Window) void {
        owos.serial.print("Trying to add window..");
        for (0..self.windows.len) |slot| {
            owos.serial.print(".");
            if (self.windows[slot] == null) {
                self.windows[slot] = window;
                owos.serial.println(" Found empty slot");
                break;
            }
        }
    }

    pub fn tick(self: *WindowManager) anyerror!u8 {
        if (owos.c.ticks % 16 == 0) {
            for (0..self.windows.len) |slot| {
                if (self.windows[slot]) |window_ptr| {
                    if (window_ptr.dirty) {
                        owos.serial.print("Window '");
                        owos.serial.print(window_ptr.name);
                        owos.serial.println("' is dirty, redrawing");
                        window_ptr.redraw();
                        owos.c.swap_buffers();
                        window_ptr.dirty = false;
                    }
                }
            }
        }
        return 2;
    }
};
