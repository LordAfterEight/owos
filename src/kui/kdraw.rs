pub struct SyncFramebuffer(pub &'static crate::limine::Framebuffer);

unsafe impl Sync for SyncFramebuffer {}
unsafe impl Send for SyncFramebuffer {}

pub static GLOBAL_FB: spin::Once<SyncFramebuffer> = spin::Once::new();

/// Panics if called before GLOBAL_FB.call_once(...) has run.
fn fb() -> &'static crate::limine::Framebuffer {
    GLOBAL_FB.get().expect("GLOBAL_FB not initialized").0
}

fn draw_glyph(
    fb: *mut u8,
    fb_stride: usize,
    bitmap: &[u8],
    glyph_w: usize,
    glyph_h: usize,
    x: usize,
    y: usize,
    color: (u8, u8, u8),
) {
    for row in 0..glyph_h {
        for col in 0..glyph_w {
            let coverage = bitmap[row * glyph_w + col];
            if coverage == 0 {
                continue;
            }

            let px_offset = (y + row) * fb_stride + (x + col) * 4;
            let alpha = coverage as u32;
            unsafe {
                core::ptr::write(
                    fb.wrapping_add(px_offset + 2),
                    ((color.0 as u32 * alpha) / 255) as u8,
                );
                core::ptr::write(
                    fb.wrapping_add(px_offset + 1),
                    ((color.1 as u32 * alpha) / 255) as u8,
                );
                core::ptr::write(
                    fb.wrapping_add(px_offset + 0),
                    ((color.2 as u32 * alpha) / 255) as u8,
                );
            }
        }
    }
}

pub fn draw_text(
    x: u32,
    y: u32,
    size: f32,
    font: &spin::Once<fontdue::Font>,
    text: &str,
    color: u32,
) {
    let fb = fb();
    let font = font.get().unwrap();

    let ascent = font
        .horizontal_line_metrics(size)
        .map(|m| m.ascent)
        .unwrap_or(size) as i32;

    let mut x_offset = 0i32;
    let mut y_offset = 0.0;
    for char in text.chars() {
        let (metrics, bitmap) = font.rasterize(char, size);

        let glyph_y = y as i32 + ascent - metrics.height as i32 - metrics.ymin;
        let glyph_x = x as i32 + x_offset + metrics.xmin;

        if char == '\n' {
            y_offset += metrics.height as f32 + 5.0;
            x_offset = 0;
            continue;
        }

        if glyph_y >= 0 && glyph_x >= 0 {
            draw_glyph(
                fb.base,
                fb.pitch as usize,
                bitmap.as_slice(),
                metrics.width,
                metrics.height,
                glyph_x as usize,
                y_offset as usize + glyph_y as usize,
                (
                    (color >> 16 & 0xFF) as u8,
                    ((color >> 8) & 0xFF) as u8,
                    (color & 0xFF) as u8,
                ),
            );
        }

        x_offset += metrics.advance_width as usize as i32;
    }
}

pub fn draw_rect(
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    t: u16,
    col: u32,
) {
    let fb = fb();
    let bpp = (fb.bpp / 8) as usize;
    let pitch = fb.pitch as usize;
    let base = fb.base;

    let t = (t as u32).max(1);
    let x_end = (x + w).min(fb.width as u32);
    let y_end = (y + h).min(fb.height as u32);

    let put_pixel = |px: u32, py: u32| {
        if px >= fb.width as u32 || py >= fb.height as u32 {
            return;
        }
        let offset = py as usize * pitch + px as usize * bpp;
        unsafe {
            let ptr = base.wrapping_add(offset);
            core::ptr::write_volatile(ptr, (col & 0xFF) as u8);
            core::ptr::write_volatile(ptr.wrapping_add(1), ((col >> 8) & 0xFF) as u8);
            core::ptr::write_volatile(ptr.wrapping_add(2), ((col >> 16) & 0xFF) as u8);
        }
    };

    for row in 0..t {
        for px in x..x_end {
            put_pixel(px, y + row);
            if y + h > row {
                put_pixel(px, y + h - 1 - row);
            }
        }
    }

    for edge in 0..t {
        for py in y..y_end {
            put_pixel(x + edge, py);
            if x + w > edge {
                put_pixel(x + w - 1 - edge, py);
            }
        }
    }
}