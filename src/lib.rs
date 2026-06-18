#![no_std]
extern crate alloc;

pub mod mem;

/// Error types for various operations.
pub mod error;

/// Drivers for hardware devices.
pub mod drivers;

/// Limine bootloader protocol structures and functions.
pub mod limine;

/// I/O port access functions.
pub mod io;

/// Kernel UI
pub mod kui;

pub const VERSION_STR: &str = "OwOS v0.1.0";