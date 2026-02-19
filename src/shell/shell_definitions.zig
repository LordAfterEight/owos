const std = @import("std");
const owos = @import("../root.zig");
const build_options = @import("build_options");

pub const InputBuffer = struct {
    tokens: [16][128]u8,
    token_counter: u8,
    char_counter: u8,

    pub fn push(self: *InputBuffer, val: u8) void {
        if (val == ' ') self.token += 1;
        self.tokens[self.token][self.char_counter] = val;
        self.char_counter += 1;
    }
};

pub const Cursor = struct {
    pos_x: u32,
    pos_y: u32,
    visible: bool,
    was_drawn: bool,
    symbol: [:0]const u8,

    pub fn init() Cursor {
        return Cursor {
            .pos_x = 0,
            .pos_y = 0,
            .visible = true,
            .was_drawn = false,
            .symbol = "_",
        };
    }

    pub fn update(self: *Cursor) void {
        if (owos.c.ticks % 50 == 0) {
            self.visible = !self.visible;
            self.was_drawn = false;
        }
    }

    pub fn newline(self: *Cursor, offset: u32) void {
        self.pos_y += offset;
        self.pos_x = 0;
    }
};


pub const Shell = struct {
    name: [:0]const u8,
    window: owos.ui.window.Window,
    cursor: Cursor,

    pub fn init(name: [:0]const u8) Shell {
        return Shell {
            .name = name,
            .window = owos.ui.window.Window.init(name),
            .cursor = Cursor.init(),
        };
    }

    pub fn once(self: *Shell) void {
        self.window.width = 800;
        self.window.height = 500;
        self.window.bg_col = 0x070707;
        if (owos.ui.owm.owm_global) |owm| {
            owm.add_window(&self.window);
        }
        self.greet();
        self.window.refresh();
    }

    pub fn deinit(self: *Shell) void {_ = self;}

    pub fn tick(self: *Shell) anyerror!u8 {
        self.cursor.update();
        if (!self.cursor.was_drawn) {
            if (self.cursor.visible) {
                self.window.draw_text(self.cursor.pos_x, self.cursor.pos_y, self.cursor.symbol, 0xFFFFFF);
            } else self.window.draw_text(self.cursor.pos_x, self.cursor.pos_y, self.cursor.symbol, self.window.bg_col);
            self.cursor.was_drawn = true;
        }
        return 2;
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32) void {
        self.window.draw_text(self.cursor.pos_x, self.cursor.pos_y, text, color);
        self.cursor.pos_x += @as(u32, @intCast(text.len)) * @as(u32, @intCast(owos.c.OwOSFont_8x16.width));
    }

    pub fn println(self: *Shell, text: [:0]const u8, color: u32) void {
        self.print(text, color);
        self.cursor.newline(owos.c.OwOSFont_8x16.height);
    }

    pub fn greet(self: *Shell) void {
        self.println(" $$$$$$\\                 $$$$$$\\   $$$$$$\\  ", 0xFF3388);
        self.println("$$  __$$\\               $$  __$$\\ $$  __$$\\ ", 0xEE3399);
        self.println("$$ /  $$ |$$\\  $$\\  $$\\ $$ /  $$ |$$ /  \\__|", 0xDD33AA);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |\\$$$$$$\\  ", 0xCC33BB);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ | \\____$$\\ ", 0xBB33CC);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |$$\\   $$ |", 0xAA33DD);
        self.println(" $$$$$$  |\\$$$$$\\$$$$  | $$$$$$  |\\$$$$$$  |", 0x9933EE);
        self.println(" \\______/  \\_____\\____/  \\______/  \\______/", 0x8833FF);
        self.cursor.newline(owos.c.OwOSFont_8x16.height);
        self.println("Welcome to OwOS :3", 0x33FF33);
    }
};
