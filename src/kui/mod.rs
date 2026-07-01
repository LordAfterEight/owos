pub mod kfont;
pub mod kdraw;
pub use kdraw::draw_text;
pub use kdraw::draw_rect;


/// Fills the screen with dark grey horizontal lines
pub fn kbackground(fb: &crate::kui::kdraw::SyncFramebuffer) {
    unsafe {
        core::ptr::write_bytes(fb.0.base, 0, fb.0.pitch as usize);
    };
}