pub const owos = @import("../root.zig");

pub fn serial_putc(char: u8) void {
    owos.c.outb(0x3F8, char);
}

pub fn serial_print(msg: []const u8) void {
    for (msg) |ch| serial_putc(ch);
    serial_putc('\n');
    serial_putc('\r');
}

pub fn serial_print_hex_u64(x: u64) void {
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

pub fn serial_print_dec_usize(v_in: usize) void {
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
