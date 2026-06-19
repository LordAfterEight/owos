pub mod kfont;
pub mod kdraw;
pub use kdraw::draw_text;


/// Fills the screen with dark grey horizontal lines
pub fn kbackground(fb: &crate::kui::kdraw::SyncFramebuffer) {
    unsafe {
        for i in 0..fb.0.height/4 {
            core::ptr::write_bytes(fb.0.base.wrapping_offset((fb.0.pitch * 4 * i).try_into().unwrap()), 20, fb.0.pitch as usize * 2);
            core::ptr::write_bytes(fb.0.base.wrapping_offset((fb.0.pitch * 4 * i + fb.0.pitch * 2).try_into().unwrap()), 25, fb.0.pitch as usize * 2);
        }
    };
}