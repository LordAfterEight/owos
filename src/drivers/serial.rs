pub const COM1: u16 = 0x3F8;

pub fn outb(port: u16, val: u8) {
    unsafe {
        core::arch::asm!(
            "out dx, al",
            in("dx") port,
            in("al") val
        );
    }
}
