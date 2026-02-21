const std = @import("std");
const owos = @import("../root.zig");
const build_options = @import("build_options");

pub const InputBuffer = struct {
    tokens: [16][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 16,
    token_counter: u8 = 0,
    char_counter: u8 = 0,

    pub fn push(self: *InputBuffer, val: u8) void {
        if (val == ' ') {
            //self.tokens[self.token_counter][self.char_counter] = 0;
            self.token_counter += 1;
            self.char_counter = 0;
        } else {
            self.tokens[self.token_counter][self.char_counter] = val;
            self.char_counter += 1;
        }
    }

    pub fn pop(self: *InputBuffer) u8 {
        const ret = self.tokens[self.token_counter][self.char_counter];
        if (self.char_counter == 0) {
            if (self.token_counter > 0) {
                self.token_counter -= 1;
            }
            for (0..self.tokens[self.token_counter][self.char_counter]) |char| {
                if (self.tokens[self.token_counter][char] == 0) {
                    self.char_counter = @intCast(char);
                    break;
                }
            }
        } else {
            if (self.char_counter > 0) {
                self.char_counter -= 1;
            }
        }
        self.tokens[self.token_counter][self.char_counter] = 0;
        return ret;
    }
};

pub const Cursor = struct {
    pos_x: u32,
    pos_y: u32,
    visible: bool,
    symbol: u8,
    last_blink_tick: u64,
    was_drawn: bool,

    pub fn init() Cursor {
        return Cursor {
            .pos_x = 0,
            .pos_y = 0,
            .visible = true,
            .symbol = '_',
            .last_blink_tick = 0,
            .was_drawn = false,
        };
    }

    pub fn update(self: *Cursor) void {
        if (owos.c.ticks - self.last_blink_tick >= 256) {
            self.last_blink_tick = owos.c.ticks;
            self.visible = !self.visible;
            self.was_drawn = false;
        }
    }

    pub fn draw(self: *Cursor, window: *owos.ui.window.Window) void {
        if (!self.was_drawn) {
            const color = if (self.visible) 0xFFFFFF else window.bg_col;
            window.draw_char(self.pos_x * 8, self.pos_y * 16, self.symbol, color);
            self.was_drawn = true;
        }
    }

    pub fn newline(self: *Cursor) void {
        self.pos_y += 1;
        self.pos_x = 0;
    }
};

pub const Shell = struct {
    char_grid: [50][149]u8 = [_][149]u8{[_]u8{' '} ** 149} ** 50,
    color_grid: [50][149]u32 = [_][149]u32{[_]u32{0} ** 149} ** 50,
    grid_dirty: bool = false,
    shell_dirty: bool = false,
    name: [:0]const u8,
    window: owos.ui.window.Window,
    cursor: Cursor,
    buffer: InputBuffer,

    pub fn init(name: [:0]const u8) Shell {
        return Shell {
            .name = name,
            .window = owos.ui.window.Window.init(name, owos.c.SCREEN_WIDTH / 2 - 602, owos.c.SCREEN_HEIGHT / 2 - 400, 1204, 800),
            .cursor = Cursor.init(),
            .buffer = InputBuffer{},
        };
    }

    pub fn once(self: *Shell) void {
        self.window.bg_col = 0x070707;
        if (owos.ui.owm.owm_global) |owm| {
            owm.add_window(&self.window);
        }
        self.window.once();
        self.greet();
        self.print("Command: ", 0xAAAAAA);
    }

    pub fn deinit(self: *Shell) void {_ = self;}

    pub fn clear(self: *Shell) void {
        for (0..50) |row| for (0..149) |col| {
            self.char_grid[row][col] = ' ';
            self.color_grid[row][col] = self.window.bg_col;
        };
        self.cursor.pos_x = 0;
        self.cursor.pos_y = 0;
        self.window.redraw_frame();
    }

    pub fn tick(self: *Shell) anyerror!u8 {
        if (self.window.dirty) return 2;
        self.handle_input();
        self.cursor.update();
        if (!self.shell_dirty and self.cursor.was_drawn) {
            return 2;
        }
        if (self.grid_dirty) {
            for (0..self.char_grid.len) |row| {
                for (0..self.char_grid[0].len) |col| {
                    const x = @as(u32, @intCast(col)) * 8;
                    const y = @as(u32, @intCast(row)) * 16;
                    self.window.draw_char(x, y, self.char_grid[row][col], self.color_grid[row][col]);
                }
            }
            self.grid_dirty = false;
            self.window.refresh();
        }
        self.cursor.draw(&self.window);
        self.window.refresh();
        return 2;
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32) void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (self.cursor.pos_y >= 50) self.clear();
            self.char_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = text[i];
            self.color_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = color;
            self.cursor.pos_x += 1;
            if (self.cursor.pos_x >= 149) {
                self.cursor.pos_x = 0;
                self.cursor.pos_y += 1;
            }
        }
        self.grid_dirty = true;
    }

    pub fn print_at(self: *Shell, x: usize, text: [:0]const u8, color: u32) void {
        self.cursor.pos_x = @intCast(x);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (self.cursor.pos_y >= 50) self.clear();
            self.char_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = text[i];
            self.color_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = color;
            self.cursor.pos_x += 1;
            if (self.cursor.pos_x >= 149) {
                self.cursor.pos_x = 0;
                self.cursor.pos_y += 1;
            }
        }
        self.grid_dirty = true;
    }

    pub fn println_at(self: *Shell, x: usize, text: [:0]const u8, color: u32) void {
        self.print_at(x, text, color);
        self.cursor.newline();
    }

    pub fn println(self: *Shell, text: [:0]const u8, color: u32) void {
        self.print(text, color);
        self.cursor.newline();
        if (self.cursor.pos_y > 50) self.cursor.pos_y = 50;
    }

    pub fn greet(self: *Shell) void {
        var buf = [_:0]u8{0} ** 32;
        self.cursor.newline();
        self.println("  $$$$$$\\                 $$$$$$\\   $$$$$$\\  ", 0xFF3388);
        self.println(" $$  __$$\\               $$  __$$\\ $$  __$$\\ ", 0xEE3399);
        self.println(" $$ /  $$ |$$\\  $$\\  $$\\ $$ /  $$ |$$ /  \\__|", 0xDD33AA);
        self.println(" $$ |  $$ |$$ | $$ | $$ |$$ |  $$ |\\$$$$$$\\  ", 0xCC33BB);
        self.println(" $$ |  $$ |$$ | $$ | $$ |$$ |  $$ | \\____$$\\ ", 0xBB33CC);
        self.println(" $$ |  $$ |$$ | $$ | $$ |$$ |  $$ |$$\\   $$ |", 0xAA33DD);
        self.println("  $$$$$$  |\\$$$$$\\$$$$  | $$$$$$  |\\$$$$$$  |", 0x9933EE);
        self.println("  \\______/  \\_____\\____/  \\______/  \\______/", 0x8833FF);
        self.cursor.newline();
        self.print(" Developer: ", 0x5555FF);
        self.println("Elias Stettmayer", 0x55FF55);
        self.print(" Repository: ", 0x5555FF);
        self.println("www.github.com/lordaftereight/owos", 0x55FF55);
        owos.c.format(@ptrCast(&buf), " Welcome to %s %s %s! :3", owos.c.KERNEL_NAME, owos.c.OS_MODEL, owos.c.KERNEL_VERSION);
        self.println(&buf, 0x22FF22);
    }

    pub fn handle_command(self: *Shell) u8 {
        if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "exit\x00")) {
            self.print(" WARNING ", 0xFF55556);
            self.println(" Exiting the shell will soft-brick the OS", 0xAAAAAA);
            self.print("Exit? (y/n) ", 0xFFFFFF);
            self.cursor.newline();
            self.println("Exiting...", 0xAAAAAA);
            owos.c.msleep(3000);
            self.clear();
            return 1;
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "proc\x00")) {
            if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[1]), "list\x00")) {
                for (owos.scheduler.global_scheduler.processes) |process| {
                    if (process != null) {
                        self.print("Process: ", 0x5555FF);
                        self.print(process.?.name, 0x5555FF);
                        self.print_at(35, "PID:", 0x5555FF);
                        var buf = [_:0]u8{0} ** 4;
                        owos.c.format(@ptrCast(&buf), "%d", process.?.id);
                        self.print_at(40, &buf, 0x5555FF);
                        if (process.?.running == true) {
                            self.println_at(45, "Running", 0x5555FF);
                        } else {
                            self.println_at(45, "Halted", 0x5555FF);
                        }
                    }
                }
            } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[1]), "kill\x00")) {
                owos.scheduler.global_scheduler.kill_process(@intCast(self.buffer.tokens[2][0] - @as(u8, '0')));
            } else {
                self.println("Usage: proc <subcmd> <arg>", 0x5555FF);
                self.println(" - list       : List all running processes", 0xFFFF55);
                self.println(" - kill <PID> : Kill process by process ID", 0xFFFF55);
            }
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "reboot\x00")) {
            asm volatile ("cli");
            var temp: u8 = undefined;
            while (true) {
                temp = owos.c.inb(0x64);
                if ((temp & 0x02) == 0) break;
            }
            owos.c.outb(0x64, 0xFE);
            while (true) {
                asm volatile ("hlt");
            }
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "info\x00")) {
            self.greet();
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "clear\x00")) {
            self.clear();
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.tokens[0]), "")) {
        } else {
            var buf = [_]u8{0} ** 32;
            self.print("Invalid command: ", 0xFF5555);
            owos.c.format(&buf, "%s ", &self.buffer.tokens[0]);
            const s:[*:0]u8 = @ptrCast(&buf);
            self.println(std.mem.span(s), 0xFFFFFF);
        }
        return 2;
    }

    pub fn handle_input(self: *Shell) void {
        const input = owos.c.ps2_poll();
        switch (input) {
            '\x08' => {
                if (self.cursor.pos_x > 0) self.cursor.pos_x -= 1;
                self.char_grid[self.cursor.pos_y][self.cursor.pos_x] = 0;
                _ = self.buffer.pop();
                self.grid_dirty = true;
                self.window.redraw();
            },
            10 => {
                self.cursor.newline();
                self.buffer.push(0);
                _ = self.handle_command();
                self.buffer.char_counter = 0;
                self.buffer.token_counter = 0;
                self.buffer.tokens = [_][256]u8{[_]u8{0} ** 256} ** 16;
                self.print("Command: ", 0xAAAAAA);
            },
            0 => {},
            else => {
                if (self.cursor.was_drawn) {
                    self.window.draw_char(self.cursor.pos_x * 8, self.cursor.pos_y * 16, '_', 0x000000);
                }
                self.print(&[1:0]u8{input}, 0xFFFFFF);
                self.buffer.push(input);
            },
        }
        if (input != 0) {
            self.grid_dirty = true;
            self.shell_dirty = true;
        }
    }
};
