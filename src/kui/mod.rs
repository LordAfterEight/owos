pub mod kfont;
pub mod kdraw;
pub use kdraw::draw_text;
pub use kdraw::draw_rect;


/// Fills the screen with dark grey horizontal lines
pub fn kbackground() {
    unsafe {
        core::ptr::write_bytes(crate::kui::kdraw::GLOBAL_FB.get().unwrap().0.base, 0, crate::kui::kdraw::GLOBAL_FB.get().unwrap().0.pitch as usize);
    };
}