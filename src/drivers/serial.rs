use core::fmt::Write;

pub const COM1: u16 = 0x3F8;

pub struct Serial;

impl Write for Serial {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for byte in s.bytes() {
            crate::io::outb(COM1, byte);
        }
        Ok(())
    }
}

/// Prints a string to serial port COM1
#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = write!($crate::drivers::serial::Serial, $($arg)*);
    }};
}

/// Prints a string to serial port COM1, followed by a newline
#[macro_export]
macro_rules! println {
    () => ($crate::print!("\n"));
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        let _ = writeln!($crate::drivers::serial::Serial, $($arg)*);
    }};
}