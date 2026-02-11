const std = @import("std");
const owos = @import("owos");
const build_options = @import("build_options");

pub const CommandBuffer = struct {
    buffer: [16][256]u8,
    token: u8,
    buffer_pos: u8,

    pub fn new() CommandBuffer {
        return CommandBuffer {
            .buffer = [_][256]u8{ [_]u8{0} ** 256 } ** 16,
            .token = 0,
            .buffer_pos = 0,
        };
    }
};

pub const Cursor = struct {
    pos_x: c_int,
    pos_y: c_int,
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
};

fn serial_putc(c: u8) void {
    owos.c.outb(0x3F8, c);
}

fn serial_print(msg: []const u8) void {
    for (msg) |ch| serial_putc(ch);
    serial_putc('\n');
    serial_putc('\r');
}

fn serial_print_hex_u64(x: u64) void {
    serial_putc('0');
    serial_putc('x');

    var shift: u6 = 60;
    while (true) {
        const nib: u4 = @truncate(x >> shift);
        const digit: u8 = if (nib < 10) ('0' + @as(u8, nib)) else ('A' + @as(u8, nib - 10));
        serial_putc(digit);
        if (shift == 0) break;
        shift -= 4;
    }

    serial_putc('\n');
    serial_putc('\r');
}

fn serial_print_dec_usize(v_in: usize) void {
    var v = v_in;
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;

    if (v == 0) {
        serial_putc('0');
        serial_putc('\n');
        serial_putc('\r');
        return;
    }

    while (v != 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }

    for (buf[i..]) |ch| serial_putc(ch);
    serial_putc('\n');
    serial_putc('\r');
}

fn read_rsp() usize {
    return asm volatile ("" : [out] "={rsp}" (-> usize));
}

pub const Shell = struct {
    buffer: CommandBuffer,
    cursor: Cursor,

    pub fn newline(self: *Shell, font: *const owos.c.Font) void {
        self.cursor.pos_x = 1;
        self.cursor.pos_y += font.height;
    }

    pub fn move_cursor(self: *Shell, columns: usize, font: *const owos.c.Font) void {
        self.cursor.pos_x += @intCast(columns * font.width);
    }

    pub fn print(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        const offset: c_int = owos.c.draw_text_wrapping(
            self.cursor.pos_x,
            self.cursor.pos_y,
            @ptrCast(text.ptr),
            color,
            invert,
            font,
        );
        self.cursor.pos_y += offset;
        self.move_cursor(owos.c.strlen(text), font);
    }

    pub fn println(self: *Shell, text: [:0]const u8, color: u32, invert: bool, font: *const owos.c.Font) void {
        self.print(text, color, invert, font);
        self.newline(font);
    }

    pub fn clear(self: *Shell) void {
        self.cursor.pos_x = 1;
        self.cursor.pos_y = 1;
        owos.c.draw_rect_f(0, 0, owos.c.SCREEN_WIDTH, owos.c.SCREEN_HEIGHT, 0x000000);
        owos.c.draw_rect_f(0, owos.c.SCREEN_HEIGHT - 20, owos.c.SCREEN_WIDTH, 20, 0x101010);
    }

    pub fn init() Shell {
        const shell = Shell {
            .buffer = CommandBuffer.new(),
            .cursor = Cursor.new(),
        };
        //shell.print("[Kernel:Shl] -> ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        //shell.println("Initialized", 0x77FF77, false, &owos.c.OwOSFont_8x16);
        return shell;
    }
    pub fn greet(self: *Shell, font: *const owos.c.Font) void {
        self.println("___________________________________________________________________", 0xFFFFFF, false, font);
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
        self.println("OwOS Kernel", 0x77FF77, false, font);

        self.print("Build Date: ", 0x7777FF, false, font);
        self.println(build_options.build_date, 0x77FF77, false, font); // or a literal like "Feb 11 2026"

        self.print("Developer: ", 0x7777FF, false, font);
        self.println("Elias Stettmayer", 0x77FF77, false, font);

        self.print("Repository: ", 0x7777FF, false, font);
        self.println("www.github.com/lordaftereight/owos-c", 0x77FF77, false, font);

        self.cursor.pos_y += 10;

        self.println("___________________________________________________________________", 0xFFFFFF, false, font);
        self.cursor.pos_y += 10;

        self.println("Welcome to OwOS :3", 0x77FF77, false, font);
        self.cursor.pos_y += 10;
    }
};