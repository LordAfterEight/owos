pub const owos = @import("../root.zig");

pub fn putc(char: u8) void {
    owos.c.outb(0x3F8, char);
}

pub fn print(msg: []const u8) void {
    for (msg) |ch| putc(ch);
}

pub fn println(msg: []const u8) void {
    print(msg);
    putc('\n');
    putc('\r');
}

pub fn print_hex_u64(x: u64) void {
    putc('0');
    putc('x');
    var shift: u6 = 60;
    while (true) {
        const nib: u4 = @truncate(x >> shift);
        const digit: u8 = if (nib < 10) ('0' + @as(u8, nib)) else ('A' + @as(u8, nib - 10));
        putc(digit);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn println_hex_u64(x: u64) void {
    print_hex_u64(x);
    putc('\n');
    putc('\r');
}

pub fn print_dec_usize(v_in: usize) void {
    var v = v_in;
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    if (v == 0) {
        putc('0');
        return;
    }
    while (v != 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    for (buf[i..]) |ch| putc(ch);
}

pub fn println_dec_usize(v_in: usize) void {
    print_dec_usize(v_in);
    putc('\n');
    putc('\r');
}
