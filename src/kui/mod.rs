pub mod kdraw;
pub mod kfont;
pub use kdraw::draw_rect;
pub use kdraw::draw_text;

pub fn kbackground() {
    unsafe {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        core::ptr::write_bytes(fb.base, 0, (fb.pitch * fb.height) as usize);
        crate::kui::draw_rect(
            10,
            55,
            crate::kui::kdraw::GLOBAL_FB.get().unwrap().0.width as u32 - 10 * 2,
            crate::kui::kdraw::GLOBAL_FB.get().unwrap().0.height as u32 - 65,
            2,
            0xC5003C,
        );
    };
}

pub fn ktitledwindow(title: &str) {
    kbackground();
    crate::kui::draw_text(
        10,
        10,
        40.0,
        &crate::kui::kfont::ORBITRON_REGULAR,
        title,
        0xC5003C,
    );
}
