pub mod kdraw;
pub mod kfont;
pub use kdraw::draw_rect;
pub use kdraw::draw_rect_f;
pub use kdraw::draw_text;
pub use kdraw::present;

/// Outer border top-left and thickness drawn by [`kbackground`].
pub const BORDER_X: u32 = 10;
pub const BORDER_Y: u32 = 55;
pub const BORDER_T: u16 = 2;
/// Pixels between the outer border bottom edge and the framebuffer bottom.
pub const OUTER_BOTTOM_MARGIN: u32 = 10;
/// Text origin offset inside the inner content rectangle.
pub const TEXT_INSET_X: u32 = 8;
pub const TEXT_INSET_Y: u32 = 3;

pub struct WindowContentRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

pub fn framebuffer_rect(fb: &crate::limine::Framebuffer) -> WindowContentRect {
    WindowContentRect {
        x: 0,
        y: 0,
        w: fb.width as u32,
        h: fb.height as u32,
    }
}

/// Inner drawable area inside the border drawn by [`kbackground`].
pub fn window_content_rect(fb: &crate::limine::Framebuffer) -> WindowContentRect {
    let t = BORDER_T as u32;
    WindowContentRect {
        x: BORDER_X + t,
        y: BORDER_Y + t,
        w: fb.width as u32 - BORDER_X * 2 - t * 2,
        h: fb.height as u32 - BORDER_Y - OUTER_BOTTOM_MARGIN - t * 2,
    }
}

pub fn window_text_origin(content: &WindowContentRect) -> (u32, u32) {
    (content.x + TEXT_INSET_X, content.y + TEXT_INSET_Y)
}

pub fn kbackground() {
    let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
    crate::kui::kdraw::clear_backbuffer(0);
    crate::kui::draw_rect(
            BORDER_X,
            BORDER_Y,
            fb.width as u32 - BORDER_X * 2,
            fb.height as u32 - BORDER_Y - OUTER_BOTTOM_MARGIN,
            BORDER_T,
            0xC5003C,
        );
}

pub fn ktitledwindow(title: &str) {
    kbackground();
    let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
    let clip = framebuffer_rect(fb);
    crate::kui::draw_text(
        15, 10, 40.0, &crate::kui::kfont::BARCODE, title, 0xC5003C, clip.x, clip.y, clip.w,
        clip.h,
    );
    let text = alloc::format!("{} v{}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
    crate::kui::draw_text(
        fb.width as u32
            - crate::kui::kdraw::text_length(&text, &crate::kui::kfont::BARCODE, 25.0) as u32
            - 20,
        fb.height as u32 - 40,
        25.0,
        &crate::kui::kfont::BARCODE,
        &text,
        0xC5003C,
        clip.x,
        clip.y,
        clip.w,
        clip.h,
    );
}
