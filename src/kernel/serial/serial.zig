const std = @import("std");

const COM1: u16 = 0x3F8;

/// Writes a single byte to serial port COM1
pub fn write_byte(byte: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [port] "N{dx}" (COM1),
          [val] "{al}" (byte),
    );
}

/// Writes a string to serial port COM1
pub fn write(msg: []const u8) void {
    for (msg) |c| write_byte(c);
}

/// Writes a string to serial port COM1, with a newline at the end
pub fn writeln(msg: []const u8) void {
    for (msg) |c| write_byte(c);
    write_byte('\n');
}

/// Writes a usize as a decimal number to serial port COM1
pub fn write_dec(n: usize) void {
    if (n == 0) { write_byte('0'); return; }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = n;
    while (v > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    write(buf[i..]);
}

/// Formats and writes to serial port COM1
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    write(s);
}

/// Formats and writes to serial port COM1 with a trailing newline
pub fn println(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    writeln(s);
}

/// Writes a u32 as exactly 6 uppercase hex digits to serial port COM1
pub fn write_hex24(n: u32) void {
    const hex = "0123456789ABCDEF";
    var shift: u5 = 20;
    while (true) {
        write_byte(hex[(n >> shift) & 0xF]);
        if (shift == 0) break;
        shift -= 4;
    }
}

/// Writes a u64 as "0x" followed by exactly 16 uppercase hex digits to serial port COM1
pub fn write_hex64(n: u64) void {
    write("0x");
    const hex = "0123456789ABCDEF";
    var shift: i8 = 60;
    while (shift >= 0) : (shift -= 4) {
        write_byte(hex[@as(usize, (n >> @as(u6, @intCast(shift))) & 0xF)]);
    }
}
