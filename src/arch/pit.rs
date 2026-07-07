use core::sync::atomic::{AtomicU64, Ordering};

const PIT_CMD: u16 = 0x43;
const PIT_CH0: u16 = 0x40;
const PIT_HZ: u32 = 1193182;
const TARGET_HZ: u32 = 100;

pub static TIMER_TICKS: AtomicU64 = AtomicU64::new(0);

pub fn init() {
    let divisor = (PIT_HZ / TARGET_HZ).max(1) as u16;
    crate::io::outb(PIT_CMD, 0x36);
    crate::io::outb(PIT_CH0, (divisor & 0xFF) as u8);
    crate::io::outb(PIT_CH0, ((divisor >> 8) & 0xFF) as u8);
}

pub fn on_tick() {
    TIMER_TICKS.fetch_add(1, Ordering::Relaxed);
    crate::arch::pic::send_eoi(crate::arch::pic::IRQ_TIMER);
}

pub fn monotonic_ms() -> u64 {
    TIMER_TICKS.load(Ordering::Relaxed)
}