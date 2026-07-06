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

/// OwOS File System
pub mod ofs;

/// Processes
pub mod proc;

/// Apps
pub mod apps;

/// Logging
pub mod klog;

/// Resources
pub mod res;