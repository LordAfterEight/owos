pub const COM1: u16 = 0x3F8;

pub fn print(s: &str) {
    for byte in s.bytes() {
        crate::io::outb(COM1, byte);
    }
}
pub fn println(s: &str) {
    print(s);
    crate::io::outb(COM1, b'\n');
}