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
