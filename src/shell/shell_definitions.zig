const std = @import("std");
const owos = @import("../root.zig");
const build_options = @import("build_options");

const cursor_border_distance = 4;

pub const CommandBuffer = struct {
    buffer: [16][256:0]u8,
    token: u8,
    buffer_pos: u8,

    pub fn new() CommandBuffer {
        return CommandBuffer {
            .buffer = undefined,
            .token = 0,
            .buffer_pos = 0,
        };
    }

    pub fn push(self: *CommandBuffer, val: u8) void {
        self.buffer[self.token][self.buffer_pos] = val;
        self.buffer_pos += 1;
    }
};

pub const Cursor = struct {
    pos_x: u32,
    pos_y: u32,
    visible: bool,
    last_toggle: usize,

    pub fn new(x: u32, y: u32) Cursor {
        return Cursor {
            .pos_x = x,
            .pos_y = y,
            .visible = true,
            .last_toggle = 0,
        };
    }

    pub fn move_right(self: *Cursor, columns: u32, font: *const owos.c.Font) void {
        self.pos_x += columns * font.width;
    }
    pub fn move_left(self: *Cursor, columns: u32, font: *const owos.c.Font) void {
        self.pos_x -= columns * font.width;
    }
    pub fn move_up(self: *Cursor, rows: u32, font: *const owos.c.Font) void {
        self.pos_y -= rows * font.height;
    }
    pub fn move_down(self: *Cursor, rows: u32, font: *const owos.c.Font) void {
        self.pos_y += rows * font.height;
    }
};

fn cStringToZSlice(p: [*c]u8) [:0]const u8 {
    const pc: [*c]const u8 = p;
    const ps: [*:0]const u8 = @ptrCast(pc);
    return std.mem.span(ps);
}

pub const Shell = struct {
    name: [:0]const u8,
    buffer: CommandBuffer,
    cursor: Cursor,
    window: owos.ui.window.Window,

    pub fn newline(self: *Shell, font: *const owos.c.Font) void {
        if (self.cursor.pos_y > self.window.pos_y + self.window.height - 16) {
            self.clear();
            self.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        } else {
            self.cursor.move_down(1, font);
        }
        self.cursor.pos_x = self.window.pos_x + cursor_border_distance + self.window.border_size;
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        if (self.cursor.pos_y > self.window.pos_y + self.window.height - 16) {
            self.clear();
        }
        const offset: u32 = @intCast(owos.c.draw_text_wrapping(
            @intCast(self.cursor.pos_x),
            @intCast(self.cursor.pos_y),
            @ptrCast(text.ptr),
            color,
            invert,
            font,
        ));
        self.cursor.pos_y += offset;
        self.cursor.move_right(owos.c.strlen(text), font);
    }

    pub fn print_at(self: *Shell, x: u32, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        const offset: u32 = @intCast(owos.c.draw_text_wrapping(
            x * font.width + self.window.pos_x + self.window.border_size + cursor_border_distance,
            @intCast(self.cursor.pos_y),
            @ptrCast(text.ptr),
            color,
            invert,
            font,
        ));
        self.cursor.pos_y += offset;
        self.cursor.move_right(owos.c.strlen(text), font);
    }

    pub fn println(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        self.print(text, color, invert, font);
        self.newline(font);
    }

    pub fn println_at(self: *Shell, x: u32, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        self.print_at(x, text, color, invert, font);
        self.newline(font);
    }

    pub fn clear(self: *Shell) void {
        self.cursor.pos_x = self.window.pos_x + cursor_border_distance + self.window.border_size;
        self.cursor.pos_y = self.window.pos_y + 22;
        owos.c.draw_rect_f(self.window.pos_x + self.window.border_size, self.window.pos_y + 20, self.window.width - self.window.border_size * 2, self.window.height - 20, self.window.bg_col);
    }

    pub fn init() Shell {
        return Shell {
            .name = "Kernel Shell",
            .buffer = CommandBuffer.new(),
            .cursor = Cursor.new(2, 2),
            .window = owos.ui.window.Window.init("Kernel Shell"),
        };
    }

    pub fn once(self: *Shell) void {
        self.window.pos_x = 40;
        self.window.pos_y = 40;
        self.window.width = 1000;
        self.window.height = 800;
        self.window.bg_col = 0x101010;
        self.window.border_size = 3;
        self.cursor.pos_x = self.window.pos_x + cursor_border_distance + self.window.border_size;
        self.cursor.pos_y = self.window.pos_y + 22;
        _ = self.window.tick();
    }

    pub fn greet(self: *Shell, font: *const owos.c.Font) void {
        self.println("___________________________________________________________________", 0xAAAAAA, false, font);
        self.cursor.pos_y += 20;
        self.println(" $$$$$$\\                 $$$$$$\\   $$$$$$\\", 0xFF7788, false, font);
        self.println("$$  __$$\\               $$  __$$\\ $$  __$$\\", 0xEE7799, false, font);
        self.println("$$ /  $$ |$$\\  $$\\  $$\\ $$ /  $$ |$$ /  \\__|", 0xDD77AA, false, font);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |\\$$$$$$\\", 0xCC77BB, false, font);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ | \\____$$\\", 0xBB77CC, false, font);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |$$\\   $$ |", 0xAA77DD, false, font);
        self.println(" $$$$$$  |\\$$$$$\\$$$$  | $$$$$$  |\\$$$$$$  |", 0x9977EE, false, font);
        self.println(" \\______/  \\_____\\____/  \\______/  \\______/", 0x8877FF, false, font);
        self.cursor.pos_y += 20;
        self.print("Kernel: ", 0x7777FF, false, font);
        self.println("OwOS Volatile", 0x77FF77, false, font);
        self.print("Kernel Version: ", 0x7777FF, false, font);
        self.println(cStringToZSlice(owos.c.KERNEL_VERSION), 0x77FF77, false, font);
        // TODO: Add build date
        // self.print("Build Date: ", 0x7777FF, false, font);
        //self.println(build_options.build_date, 0x77FF77, false, font); // or a literal like "Feb 11 2026"
        self.print("Developer: ", 0x7777FF, false, font);
        self.println("Elias Stettmayer", 0x77FF77, false, font);
        self.print("Repository: ", 0x7777FF, false, font);
        self.println("www.github.com/lordaftereight/owos-c", 0x77FF77, false, font);
        self.cursor.pos_y += 10;
        self.println("___________________________________________________________________", 0xAAAAAA, false, font);
        self.cursor.pos_y += 10;
        self.println("Welcome to OwOS :3", 0x77FF77, false, font);
        self.cursor.pos_y += 10;
    }

    pub fn handle_input(self: *Shell) u8 {
        self.cursor.pos_y += 16;
        self.cursor.pos_x = self.window.pos_x + cursor_border_distance + self.window.border_size;
        if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "exit")) {
            self.print(" WARNING ", 0xFF5555, true, &owos.c.OwOSFont_8x16);
            self.println(" Exiting the shell will soft-brick the OS", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            self.print("Exit? (y/n) ", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
            while (true) {
                asm volatile ("hlt");
                const c = owos.c.getchar_polling();
                if (c != 0) {
                    if (c == 'y') {
                        self.print("y", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                        self.newline(&owos.c.OwOSFont_8x16);
                        self.println("Exiting...", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
                        owos.c.msleep(3000);
                        self.clear();
                        return 1;
                    }
                    else {
                        self.println("aborted", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                        break;
                    }
                }
            }
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "proc")) {
            if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[1]), "list")) {
                for (owos.scheduler.global_scheduler.processes) |process| {
                    if (process != null) {
                        self.print("Process: ", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        self.print(process.?.name, 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        self.print_at(25, "PID:", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        var buf = [_:0]u8{0} ** 4;
                        owos.c.format(@ptrCast(&buf), "%d", process.?.id);
                        self.print_at(29, &buf, 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        if (process.?.running == true) {
                            self.println_at(32, "Running", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        } else {
                            self.println_at(32, "Halted", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                        }
                    }
                }
            } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[1]), "kill")) {
                self.print("Are you sure? (y/n) ", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                while (true) {
                    asm volatile ("hlt");
                    const c = owos.c.getchar_polling();
                    if (c != 0) {
                        if (c == 'y') {
                            owos.scheduler.global_scheduler.kill_process(@intCast(self.buffer.buffer[2][0] - @as(u8, '0')));
                            break;
                        }
                        else {
                            self.println("aborted", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                            break;
                        }
                    }
                }
            } else {
                self.print("Invalid proc command: ", 0xFF7777, false, &owos.c.OwOSFont_8x16);
                self.println(&self.buffer.buffer[1], 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            }
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "reboot")) {
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
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "info")) {
            self.greet(&owos.c.OwOSFont_8x16);
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "clear")) {
            self.clear();
        } else if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "")) {
        } else {
            var buf = [_]u8{0} ** 32;
            self.print("Invalid command: ", 0xFF7777, false, &owos.c.OwOSFont_8x16);
            owos.c.format(&buf, "%s", &self.buffer.buffer[0]);
            const s:[*:0]u8 = @ptrCast(&buf);
            self.println(std.mem.span(s), 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
        }
        return 2;
    }

    pub fn update_cursor(self: *Shell) void {
        if (self.cursor.pos_y > self.window.pos_y + self.window.height - 32) {
            self.clear();
            self.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        }
        if (owos.c.ticks - self.cursor.last_toggle >= 250) {
            self.cursor.last_toggle = owos.c.ticks;
            self.cursor.visible = !self.cursor.visible;
            if (self.cursor.visible) {
                if (self.cursor.pos_x < self.window.pos_x + self.window.width - 8) {
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
                }
            } else {
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', self.window.bg_col, false, &owos.c.OwOSFont_8x16);
            }
        }
    }

    pub fn update_buffer(self: *Shell) u8 {
        const c = owos.c.getchar_polling();
        var result: u8 = 2;
        if (c != 0) {
            if (c == ' ') {
                self.buffer.push(0);
                self.buffer.token += 1;
                self.buffer.buffer_pos = 0;
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', self.window.bg_col, false, &owos.c.OwOSFont_8x16);
                self.cursor.move_right(1, &owos.c.OwOSFont_8x16);
            }
            else if (c == '\n' or c == '\r') {
                //beep(1000, 25);
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', self.window.bg_col, false, &owos.c.OwOSFont_8x16);
                self.buffer.push(0);
                result = self.handle_input();
                _ = owos.c.owos_memset(&self.buffer.buffer, 0, @sizeOf(CommandBuffer));
                if (result == 1) return 1;
                self.buffer.buffer_pos = 0;
                self.buffer.token = 0;
                self.cursor.pos_x = self.window.pos_x + cursor_border_distance + self.window.border_size;
                self.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            } else if (c == '\x08') {
                if (self.cursor.pos_x != 0 and self.buffer.buffer_pos != 0) {
                    self.buffer.buffer_pos -= 1;
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', self.window.bg_col, false, &owos.c.OwOSFont_8x16);
                    self.cursor.move_left(1, &owos.c.OwOSFont_8x16);
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y, self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos], self.window.bg_col, false, &owos.c.OwOSFont_8x16);
                    self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos] = 0;
                }
            } else {
                self.buffer.push(c);
                if (self.cursor.pos_x < self.window.pos_x + self.window.width - 8) {
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', self.window.bg_col, false, &owos.c.OwOSFont_8x16);
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y, self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos - 1], 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                    self.cursor.move_right(1, &owos.c.OwOSFont_8x16);
                }
            }
        }
        return result;
    }

    pub fn update(self: *Shell) u8 {
        self.update_cursor();
        return self.update_buffer();
    }

    pub fn tick(self: *Shell) u8 {
        return self.update();
    }

    pub fn deinit(self: *Shell) void {
        self.clear();
    }
};
