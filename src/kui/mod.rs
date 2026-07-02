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
        15,
        10,
        40.0,
        &crate::kui::kfont::BARCODE,
        title,
        0xC5003C,
    );
    let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
    let text = alloc::format!("{} v{}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
    crate::kui::draw_text(
        fb.width as u32 - crate::kui::kdraw::text_length(&text, &crate::kui::kfont::BARCODE, 25.0) as u32 - 20,
        fb.height as u32 - 40,
        25.0,
        &crate::kui::kfont::BARCODE,
        &text,
        0xC5003C,
    );
}
