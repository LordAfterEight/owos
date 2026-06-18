pub mod kfont;
pub use kfont::Kfont;

/// Fills the screen with dark grey horizontal lines
pub fn kbackground(fb: &crate::limine::Framebuffer) {
    unsafe {
        for i in 0..fb.height/4 {
            core::ptr::write_bytes(fb.base.wrapping_offset((fb.pitch * 4 * i).try_into().unwrap()), 20, fb.pitch as usize * 2);
            core::ptr::write_bytes(fb.base.wrapping_offset((fb.pitch * 4 * i + fb.pitch * 2).try_into().unwrap()), 30, fb.pitch as usize * 2);
        }
    };
}