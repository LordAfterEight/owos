pub mod faults;
pub mod gdt;
pub mod idt;
pub mod isr;
pub mod pic;
pub mod pit;

pub fn init() {
    gdt::init();
    idt::init();
    pic::init();
    pit::init();
}

pub fn enable_interrupts() {
    pic::unmask_irq(pic::IRQ_TIMER);
    x86_64::instructions::interrupts::enable();
}