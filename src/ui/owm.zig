const owos = @import("../root.zig");

pub var owm_global: ?*WindowManager = null;

pub const WindowManager = struct {
    name: [:0]const u8,
    windows: [16]?*owos.ui.window.Window,
    last_tick: u32,

    pub fn init(stub: [:0]const u8) WindowManager {
        _ = stub;
        return WindowManager {
            .name = "OwOS Window Manager",
            .windows = .{null} ** 16,
            .last_tick = 0,
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
        var desktop_dirty = false;
        for (self.windows) |maybe_window| {
            if (maybe_window) |win| {
                if (win.dirty) {
                    win.redraw();
                    win.dirty = false;
                    desktop_dirty = true;
                }
            }
        }

        if (desktop_dirty and owos.c.ticks - self.last_tick >= 16) {
            self.last_tick = owos.c.ticks;
            //_ = owos.c.owos_memcpy(@volatileCast(@ptrCast(&owos.c.back_buffer.*)), @ptrCast(&owos.c.wallpaper.*), 1920*1040*4);

            for (self.windows) |maybe_window| {
                if (maybe_window) |win| {
                    if (win.dirty) {
                        win.redraw();
                        win.dirty = false;
                    }

                    const win_x: i32 = @intCast(win.pos_x);
                    const win_y: i32 = @intCast(win.pos_y);
                    const win_w: i32 = @intCast(win.width);
                    //const win_h: i32 = @intCast(win.height);
                    const screen_w: i32 = @intCast(owos.c.SCREEN_WIDTH);
                    const screen_h: i32 = @intCast(owos.c.SCREEN_HEIGHT);

                    for (0..win.height) |y_usize| {
                        const y: i32 = @intCast(y_usize);
                        const screen_y = win_y + y;

                        if (screen_y < 0) continue;
                        if (screen_y >= screen_h) break;

                        var start_x = win_x;
                        var src_x: i32 = 0;
                        var copy_w = win_w;

                        if (start_x < 0) {
                            src_x = -start_x;
                            copy_w -= src_x;
                            start_x = 0;
                        }

                        if (start_x + copy_w > screen_w) {
                            copy_w = screen_w - start_x;
                        }

                        if (copy_w <= 0) continue;

                        const dest_idx = @as(usize, @intCast(screen_y * screen_w + start_x));
                        const src_idx = @as(usize, @intCast(y * win_w + src_x));
                        const copy_len = @as(usize, @intCast(copy_w));

                        @memcpy(
                            owos.c.back_buffer[dest_idx .. dest_idx + copy_len],
                            win.framebuffer[src_idx .. src_idx + copy_len]
                        );
                    }
                }
            }

            owos.c.swap_buffers();
        }
        return 2;
    }


};
