const owos = @import("../root.zig");

pub var owm_global = WindowManager.init();

pub const WindowManager = struct {
    name: [:0]const u8,
    windows: [16]?owos.ui.window.Window,

    pub fn init(stub: [:0]const u8) WindowManager {
        _ = stub;
        return WindowManager {
            .name = "OWM",
            .windows = .{null} ** 16,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        _ = self;
    }

    pub fn once(self: *WindowManager) void {
        _ = self;
    }

    pub fn add_window(self: *WindowManager, window: owos.ui.window.Window) void {
        for (0..self.windows.len) |slot| {
            if (self.windows[slot] != null) {
                self.windows[slot] = window;
            }
        }
    }

    pub fn tick(self: *WindowManager) anyerror!u8 {
        _ = self;
        return 2;
    }
};
