const owos = @import("../root.zig");

pub const MouseCursor = struct {
    name: [:0]const u8,
    pos_x: u32,
    pos_y: u32,

    pub fn init() MouseCursor {
        owos.c.ps2_mouse_init();
        owos.c.ps2_set_screen_bounds(@intCast(owos.c.SCREEN_WIDTH), @intCast(owos.c.SCREEN_HEIGHT));
        return MouseCursor {
            .name = "Mouse Cursor",
            .pos_x = 100,
            .pos_y = 100,
        };
    }

    pub fn deinit(self: *MouseCursor) void {
        _ = self;
    }

    pub fn once(self: *MouseCursor) void {
        _ = self;
    }

    pub fn tick(self: *MouseCursor) u8 {
        while (true) {
            _ = owos.c.ps2_poll();
            if ((owos.c.inb(0x64) & 0x01) == 0) break;
        }

        const mouse_state = owos.c.ps2_get_mouse_state();
        owos.c.draw_rect_f(self.pos_x, self.pos_y, 10, 10, 0x000000);
        if (mouse_state.*.x > 0 and mouse_state.*.x < owos.c.SCREEN_WIDTH - 10) {
            self.pos_x = @intCast(mouse_state.*.x);
        }
        if (mouse_state.*.y > 0 and mouse_state.*.y < owos.c.SCREEN_HEIGHT - 10) {
            self.pos_y = @intCast(mouse_state.*.y);
        }
        owos.c.draw_rect_f(self.pos_x, self.pos_y, 10, 10, 0xFFFFFF);
        return 2;
    }
};
