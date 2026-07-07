const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x11;
const ICW4_8086: u8 = 0x01;

pub const IRQ_TIMER: u8 = 0;
pub const PIC1_OFFSET: u8 = 32;

pub fn init() {
    x86_64::instructions::interrupts::disable();

    crate::io::outb(PIC1_CMD, ICW1_INIT);
    crate::io::outb(PIC2_CMD, ICW1_INIT);
    crate::io::outb(PIC1_DATA, PIC1_OFFSET);
    crate::io::outb(PIC2_DATA, PIC1_OFFSET + 8);
    crate::io::outb(PIC1_DATA, 4);
    crate::io::outb(PIC2_DATA, 2);
    crate::io::outb(PIC1_DATA, ICW4_8086);
    crate::io::outb(PIC2_DATA, ICW4_8086);

    mask_all();
}

fn mask_all() {
    crate::io::outb(PIC1_DATA, 0xFF);
    crate::io::outb(PIC2_DATA, 0xFF);
}

pub fn unmask_irq(irq: u8) {
    let (port, irq_line) = if irq < 8 {
        (PIC1_DATA, irq)
    } else {
        (PIC2_DATA, irq - 8)
    };
    let mask = crate::io::inb(port) & !(1 << irq_line);
    crate::io::outb(port, mask);
}

pub fn send_eoi(irq: u8) {
    if irq >= 8 {
        crate::io::outb(PIC2_CMD, 0x20);
    }
    crate::io::outb(PIC1_CMD, 0x20);
}