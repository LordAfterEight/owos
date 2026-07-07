pub mod compositor_ipc;
pub mod kdraw;
pub mod kfont;
pub mod window;

pub use kdraw::draw_rect_f_in_window;
pub use kdraw::draw_rect_in_window;
pub use kdraw::draw_text_in_window;
pub use window::window_text_origin;
pub use window::WindowHandle;

/// Border thickness around the content area.
pub const BORDER_T: u16 = 2;
/// Border thickness of the title bar.
pub const TITLE_BAR_BORDER: u16 = 1;
/// Title bar height (above the content border).
pub const TITLE_BAR_H: u32 = 26;
/// Font size for window titles drawn by the compositor.
pub const TITLE_FONT_SIZE: f32 = 20.0;

pub const PALETTE_MAGENTA: u32 = 0xC5003C;
pub const PALETTE_AMBER: u32 = 0xF3C200;
pub const PALETTE_CYAN: u32 = 0x55EAD4;
pub const PALETTE_LIGHT_CYAN: u32 = 0x9BE8FF;
pub const PALETTE_ORANGE: u32 = 0xF38020;
pub const PALETTE_MUTED: u32 = 0x5A9EAA;
/// Opacity of frosted window backgrounds (70% black tint).
pub const WINDOW_BG_ALPHA: u8 = 100;
/// Separable box-blur radius (9-tap horizontal + vertical).
pub const BLUR_RADIUS: i32 = 4;
/// Text origin offset inside the inner content rectangle.
pub const TEXT_INSET_X: u32 = 8;
pub const TEXT_INSET_Y: u32 = 3;

/// Legacy layout constants used when computing default window frames.
pub const BORDER_X: u32 = 10;
pub const BORDER_Y: u32 = 55;
pub const OUTER_BOTTOM_MARGIN: u32 = 10;

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
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

/// Flush the backbuffer to the framebuffer. For kernel emergency paths (panic) only.
pub fn present_emergency() {
    kdraw::present();
}

pub fn default_shell_frame(fb: &crate::limine::Framebuffer) -> window::FrameRect {
    window::FrameRect {
        x: BORDER_X,
        y: BORDER_Y,
        w: fb.width as u32 - BORDER_X * 2,
        h: fb.height as u32 - BORDER_Y - OUTER_BOTTOM_MARGIN,
    }
}