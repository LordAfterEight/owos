#![no_std]
extern crate alloc;

pub mod mem;

/// Error types for various operations.
pub mod error;

/// CPU architecture (GDT, IDT, interrupts).
pub mod arch;

/// Drivers for hardware devices.
pub mod drivers;

/// Limine bootloader protocol structures and functions.
pub mod limine;

/// I/O port access functions.
pub mod io;

/// Kernel UI
pub mod kui;

/// OwOS File System
pub mod ofs;

/// Monotonic time and frame delta.
pub mod time;

/// Processes
pub mod proc;

/// Apps
pub mod apps;

/// Language tooling
pub mod lang;

/// Userspace program runtime (loader, syscalls, terminal)
pub mod runtime;

/// Logging
pub mod klog;

/// Resources
pub mod res;