const std = @import("std");
const owos = @import("../root.zig");

pub const TaskBar = struct {
    name: [:0]const u8,
    bg_col: u32,
    fg_col: u32,
    time: [64]u8,

    pub fn init() TaskBar {
        owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 24, owos.c.SCREEN_WIDTH, 24, 0x202020);
            owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 24, owos.c.SCREEN_WIDTH, 1, 0x2F2F2F);
        var taskbar = TaskBar {
            .name = "Taskbar",
            .bg_col = 0x202020,
            .fg_col = 0xAAAAAA,
            .time = [_]u8{0} ** 64,
        };
        taskbar.draw_clock();
        return taskbar;
    }

    pub fn once(self: *TaskBar) void {
        _ = self;
    }

    pub fn draw_clock(self: *TaskBar) void {
        const len0: usize = @intCast(owos.c.strlen(@ptrCast(&self.time)));
        owos.c.draw_text(
            owos.c.SCREEN_WIDTH - @as(u32, @intCast(len0 * 8 + 5)),
            owos.c.SCREEN_HEIGHT - 20,
            @ptrCast(&self.time),
            0x101010,
            false,
            &owos.c.OwOSFont_8x16,
        );

        _ = owos.c.owos_memset(@ptrCast(&self.time), 0, self.time.len);

        owos.c.read_rtc();

        _ = owos.c.format(
            @ptrCast(&self.time),
            "%d:%d:%d - %d.%d.%d",
            owos.c.hour + 1,
            owos.c.minute,
            owos.c.second,
            owos.c.day,
            owos.c.month,
            owos.c.year,
        );

        const len1: usize = @intCast(owos.c.strlen(@ptrCast(&self.time)));
        owos.c.draw_text(
            owos.c.SCREEN_WIDTH - @as(u32, @intCast(len1 * 8 + 5)),
            owos.c.SCREEN_HEIGHT - 20,
            @ptrCast(&self.time),
            0xAAAAAA,
            false,
            &owos.c.OwOSFont_8x16,
        );
    }


    pub fn tick(self: *TaskBar) u8 {
        if (owos.c.ticks % 1000 == 0) {
            owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 24, owos.c.SCREEN_WIDTH, 24, 0x202020);
            owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 24, owos.c.SCREEN_WIDTH, 1, 0x2F2F2F);
            owos.c.draw_text(5, owos.c.SCREEN_HEIGHT - 20, owos.c.KERNEL_NAME, 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            owos.c.draw_text(5 + owos.c.strlen(owos.c.KERNEL_NAME) * 8 + 8, owos.c.SCREEN_HEIGHT - 20, owos.c.OS_MODEL, 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            self.draw_clock();
        }
        return 2;
    }

    pub fn deinit(self: *TaskBar) void {
        self.time = [_]u8{0} ** 64;
    }
};

