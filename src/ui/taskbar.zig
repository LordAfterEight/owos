const std = @import("std");
const owos = @import("../root.zig");

pub const TaskBar = struct {
    name: [:0]const u8,
    bg_col: u32,
    fg_col: u32,
    title_col: u32,
    titlebar_col: u32,
    titlebar_inner_col: u32,
    border_col: u32,
    border_size: u8,
    has_border: bool,
    inner_shadow: bool,
    shadow_size: u8,
    light_edge_color: u32,
    dark_edge_color: u32,
    last_render_tick: u32,
    time: [64]u8,

    pub fn init(name: [:0]const u8) TaskBar {
        var taskbar = TaskBar{
            .name = name,
            .bg_col = 0x8A8984,
            .fg_col = 0xFFFFFF,
            .title_col = 0xCCCCCC,
            .titlebar_col = 0xB3B1AA,
            .titlebar_inner_col = 0x505050,
            .border_col = 0xB3B1AA,
            .border_size = 4,
            .has_border = true,
            .inner_shadow = true,
            .shadow_size = 5,
            .light_edge_color = 0xAAAAAA,
            .dark_edge_color = 0x444444,
            .last_render_tick = 0,
            .time = [_]u8{0} ** 64,
        };
        taskbar.draw_clock();
        return taskbar;
    }

    pub fn once(self: *TaskBar) void {
        owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 35, owos.c.SCREEN_WIDTH, 35, self.bg_col);
        owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 35, owos.c.SCREEN_WIDTH, 1, self.light_edge_color);
    }

    pub fn draw_clock(self: *TaskBar) void {
        const len0: usize = @intCast(owos.c.strlen(@ptrCast(&self.time)));
        owos.c.draw_text(
            owos.c.SCREEN_WIDTH - @as(u32, @intCast(len0 * 8 + 5)),
            owos.c.SCREEN_HEIGHT - 20,
            @ptrCast(&self.time),
            self.titlebar_inner_col,
            false,
            &owos.c.OwOSFont_8x16,
        );

        _ = owos.c.owos_memset(@ptrCast(&self.time), 0, self.time.len);

        owos.c.read_rtc();

        _ = owos.c.format(
            @ptrCast(&self.time),
            "%d:%d:%d",
            owos.c.hour + 1,
            owos.c.minute,
            owos.c.second,
        );

        const len2: usize = @intCast(owos.c.strlen(@ptrCast(&self.time)));
        owos.c.draw_text(
            owos.c.SCREEN_WIDTH - @as(u32, @intCast(len2 * 8 + 5)),
            owos.c.SCREEN_HEIGHT - 34,
            @ptrCast(&self.time),
            self.fg_col,
            false,
            &owos.c.OwOSFont_8x16,
        );

        _ = owos.c.format(
            @ptrCast(&self.time),
            "%d.%d.%d",
            owos.c.day,
            owos.c.month,
            owos.c.year,
        );

        const len1: usize = @intCast(owos.c.strlen(@ptrCast(&self.time)));
        owos.c.draw_text(
            owos.c.SCREEN_WIDTH - @as(u32, @intCast(len1 * 8 + 5)),
            owos.c.SCREEN_HEIGHT - 18,
            @ptrCast(&self.time),
            self.fg_col,
            false,
            &owos.c.OwOSFont_8x16,
        );

    }

    pub fn tick(self: *TaskBar) u8 {
        if (self.last_render_tick - owos.c.ticks >= 16) {
            owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 37, owos.c.SCREEN_WIDTH, 37, self.titlebar_inner_col);
            owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 37, owos.c.SCREEN_WIDTH, 1, self.light_edge_color);
            owos.c.draw_text(5, owos.c.SCREEN_HEIGHT - 26, owos.c.KERNEL_NAME, self.fg_col, false, &owos.c.OwOSFont_8x16);
            owos.c.draw_text(5 + owos.c.strlen(owos.c.KERNEL_NAME) * 8 + 8, owos.c.SCREEN_HEIGHT - 26, owos.c.OS_MODEL, self.fg_col, false, &owos.c.OwOSFont_8x16);
            self.draw_clock();
            for (0..owos.scheduler.global_scheduler.processes.len) |slot| {
                if (owos.scheduler.global_scheduler.processes[slot] != null) {
                    const x_pos = self.calc_x_pos(slot);
                    // bg
                    owos.c.draw_rect_f(
                        x_pos,
                        owos.c.SCREEN_HEIGHT - 33,
                        @as(u32, @intCast(owos.scheduler.global_scheduler.processes[slot].?.name.len)) * 8 + 16,
                        28,
                        self.bg_col
                    );
                    // top inner shadow
                    owos.c.draw_rect_f(
                        x_pos,
                        owos.c.SCREEN_HEIGHT - 33,
                        @as(u32, @intCast(owos.scheduler.global_scheduler.processes[slot].?.name.len)) * 8 + 16,
                        1,
                        self.light_edge_color
                    );
                    // bottom light edge
                    owos.c.draw_rect_f(
                        x_pos + 1,
                        owos.c.SCREEN_HEIGHT - 5,
                        @as(u32, @intCast(owos.scheduler.global_scheduler.processes[slot].?.name.len)) * 8 + 16,
                        1,
                        self.dark_edge_color
                    );
                    // left edge shadow
                    owos.c.draw_rect_f(
                        x_pos,
                        owos.c.SCREEN_HEIGHT - 32,
                        1,
                        27,
                        self.light_edge_color
                    );
                    // right light edge
                    owos.c.draw_rect_f(
                        x_pos + @as(u32, @intCast(owos.scheduler.global_scheduler.processes[slot].?.name.len)) * 8 + 16,
                        owos.c.SCREEN_HEIGHT - 32,
                        1,
                        27,
                        self.dark_edge_color
                    );
                    // Process name
                    owos.c.draw_text(
                        x_pos + 8,
                        owos.c.SCREEN_HEIGHT - 26,
                        @ptrCast(owos.scheduler.global_scheduler.processes[slot].?.name.ptr),
                        self.fg_col,
                        false,
                        &owos.c.OwOSFont_8x16
                    );
                }
            }
        }
        return 2;
    }

    pub fn calc_x_pos(self: *TaskBar, offset: usize) u32 {
        _ = self;
        return 150 + @as(u32, @intCast((offset * 3) * (9 * owos.scheduler.global_scheduler.processes[offset].?.name.len)));
    }

    pub fn deinit(self: *TaskBar) void {
        self.time = [_]u8{0} ** 64;
    }
};
