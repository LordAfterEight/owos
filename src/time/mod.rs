use core::sync::atomic::{AtomicU64, Ordering};

static LAST_MONOTONIC_MS: AtomicU64 = AtomicU64::new(0);
static FRAME_DELTA_MS: AtomicU64 = AtomicU64::new(0);

pub fn update() {
    let now = crate::arch::pit::monotonic_ms();
    let last = LAST_MONOTONIC_MS.swap(now, Ordering::Relaxed);
    let delta = now.saturating_sub(last);
    FRAME_DELTA_MS.store(delta.min(u32::MAX as u64), Ordering::Relaxed);
}

pub fn delta_ms() -> u32 {
    FRAME_DELTA_MS.load(Ordering::Relaxed) as u32
}

pub fn monotonic_ms() -> u64 {
    crate::arch::pit::monotonic_ms()
}