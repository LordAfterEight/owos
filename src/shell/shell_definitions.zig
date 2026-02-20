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
        const time = owos.c.second;
        if (time - self.last_blink_tick > 0) {
            self.last_blink_tick = owos.c.second;
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
    char_grid: [25][80]u8 = [_][80]u8{[_]u8{' '} ** 80} ** 25,
    color_grid: [25][80]u32 = [_][80]u32{[_]u32{0} ** 80} ** 25,
    grid_dirty: bool = false,
    name: [:0]const u8,
    window: owos.ui.window.Window,
    cursor: Cursor,

    pub fn init(name: [:0]const u8) Shell {
        return Shell {
            .name = name,
            .window = owos.ui.window.Window.init(name, 800, 500),
            .cursor = Cursor.init(),
        };
    }

    pub fn once(self: *Shell) void {
        self.window.bg_col = 0x070707;
        if (owos.ui.owm.owm_global) |owm| {
            owm.add_window(&self.window);
        }
        self.greet();
    }

    pub fn deinit(self: *Shell) void {_ = self;}

    pub fn clear(self: *Shell) void {
        for (0..25) |row| for (0..80) |col| {
            self.char_grid[row][col] = ' ';
            self.color_grid[row][col] = self.window.bg_col;
        };
        self.cursor.pos_x = 0;
        self.cursor.pos_y = 0;
    }

    pub fn tick(self: *Shell) anyerror!u8 {
        if (self.window.dirty) return 2;
        self.cursor.update();
        if (self.grid_dirty or self.cursor.was_drawn == false) {
            for (0..self.char_grid.len) |row| {
                for (0..self.char_grid[0].len) |col| {
                    const x = @as(u32, @intCast(col)) * 8;
                    const y = @as(u32, @intCast(row)) * 16;
                    self.window.draw_char(x, y, self.char_grid[row][col], self.color_grid[row][col]);
                }
            }
            self.grid_dirty = false;
            self.cursor.draw(&self.window);
            self.window.refresh();
        }
        return 2;
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32) void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (self.cursor.pos_y >= 25) return;
            self.char_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = text[i];
            self.color_grid[@intCast(self.cursor.pos_y)][@intCast(self.cursor.pos_x)] = color;
            self.cursor.pos_x += 1;
            if (self.cursor.pos_x >= 80) {
                self.cursor.pos_x = 0;
                self.cursor.pos_y += 1;
            }
            owos.serial.print(&[1:0]u8{text[i]});
        }
        self.grid_dirty = true;
    }

    pub fn println(self: *Shell, text: [:0]const u8, color: u32) void {
        self.print(text, color);
        owos.serial.println("");
        self.cursor.newline();
        if (self.cursor.pos_y >= 25) self.cursor.pos_y = 24;
    }

    pub fn greet(self: *Shell) void {
        self.cursor.newline();
        self.println(" $$$$$$\\                 $$$$$$\\   $$$$$$\\  ", 0xFF3388);
        self.println("$$  __$$\\               $$  __$$\\ $$  __$$\\ ", 0xEE3399);
        self.println("$$ /  $$ |$$\\  $$\\  $$\\ $$ /  $$ |$$ /  \\__|", 0xDD33AA);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |\\$$$$$$\\  ", 0xCC33BB);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ | \\____$$\\ ", 0xBB33CC);
        self.println("$$ |  $$ |$$ | $$ | $$ |$$ |  $$ |$$\\   $$ |", 0xAA33DD);
        self.println(" $$$$$$  |\\$$$$$\\$$$$  | $$$$$$  |\\$$$$$$  |", 0x9933EE);
        self.println(" \\______/  \\_____\\____/  \\______/  \\______/", 0x8833FF);
        self.cursor.newline();
        self.println("Welcome to OwOS :3", 0x33FF33);
    }
};
