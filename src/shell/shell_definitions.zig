const std = @import("std");
const owos = @import("../root.zig");
const build_options = @import("build_options");

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

    pub fn new() Cursor {
        return Cursor {
            .pos_x = 0,
            .pos_y = 0,
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
    name: []const u8,
    buffer: CommandBuffer,
    cursor: Cursor,

    pub fn newline(self: *Shell, font: *const owos.c.Font) void {
        self.cursor.move_down(1, font);
        self.cursor.pos_x = 1;
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
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

    pub fn println(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        self.print(text, color, invert, font);
        self.newline(font);
    }

    pub fn clear_clean(self: *Shell) void {
        self.cursor.pos_x = 1;
        self.cursor.pos_y = 1;
        owos.c.draw_rect_f(0, 0, owos.c.SCREEN_WIDTH, owos.c.SCREEN_HEIGHT, 0x000000);
    }

    pub fn clear(self: *Shell) void {
        self.clear_clean();
    }

    pub fn init() Shell {
        var shell = Shell {
            .name = "Kernel Shell",
            .buffer = CommandBuffer.new(),
            .cursor = Cursor.new(),
        };
        shell.print("[Kernel:Shl] -> ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        shell.println("Initialized", 0x77FF77, false, &owos.c.OwOSFont_8x16);
        shell.newline(&owos.c.OwOSFont_8x16);
        shell.greet(&owos.c.OwOSFont_8x16);
        shell.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        return shell;
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
        self.cursor.pos_x = 1;
        if (owos.c.strcmp(@ptrCast(&self.buffer.buffer[0]), "exit")) {
            self.print(" WARNING ", 0xFF5555, true, &owos.c.OwOSFont_8x16);
            self.println(" Exiting the shell will soft-brick the OS", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            self.print("Exit? (y/n) ", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
            while (true) {
                const c = owos.c.getchar_polling();
                if (c != 0) {
                    if (c == 'y') {
                        self.print("y", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                        self.newline(&owos.c.OwOSFont_8x16);
                        self.println("Exiting...", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
                        owos.c.msleep(3000);
                        self.clear_clean();
                        return 1;
                    }
                    else {
                        self.println("aborted", 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                        return 2;
                    }
                }
            }
        }
        return 2;
    }

    pub fn update_cursor(self: *Shell) void {
        if (self.cursor.pos_y > owos.c.SCREEN_HEIGHT - 45) {
            self.clear();
        }
        if (owos.c.ticks - self.cursor.last_toggle >= 250) {
            self.cursor.last_toggle = owos.c.ticks;
            self.cursor.visible = !self.cursor.visible;
            if (self.cursor.visible) {
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            } else {
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0x000000, false, &owos.c.OwOSFont_8x16);
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
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0x000000, false, &owos.c.OwOSFont_8x16);
                self.cursor.move_right(1, &owos.c.OwOSFont_8x16);
            }
            else if (c == '\n' or c == '\r') {
                //beep(1000, 25);
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0x000000, false, &owos.c.OwOSFont_8x16);
                self.buffer.push(0);
                result = self.handle_input();
                _ = owos.c.owos_memset(&self.buffer.buffer, 0, @sizeOf(CommandBuffer));
                if (result == 1) return 1;
                self.buffer.buffer_pos = 0;
                self.buffer.token = 0;
                self.cursor.pos_x = 1;
                self.print("Command: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            } else if (c == '\x08') {
                if (self.cursor.pos_x != 0 and self.buffer.buffer_pos != 0) {
                    self.buffer.buffer_pos -= 1;
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0x000000, false, &owos.c.OwOSFont_8x16);
                    self.cursor.move_left(1, &owos.c.OwOSFont_8x16);
                    owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y, self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos], 0x000000, false, &owos.c.OwOSFont_8x16);
                    self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos] = 0;
                }
            } else {
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y + 16, '^', 0x000000, false, &owos.c.OwOSFont_8x16);
                self.buffer.push(c);
                owos.c.draw_char(self.cursor.pos_x, self.cursor.pos_y, self.buffer.buffer[self.buffer.token][self.buffer.buffer_pos - 1], 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                self.cursor.move_right(1, &owos.c.OwOSFont_8x16);
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
        self.clear_clean();
    }
};
