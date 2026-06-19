pub static mut GLOBAL_FB: spin::Once<&crate::limine::Framebuffer> = spin::Once::new();

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
            if coverage == 0 { continue; }

            let px_offset = (y + row) * fb_stride + (x + col) * 4;
            let alpha = coverage as u32;
            unsafe {
                core::ptr::write(fb.wrapping_add(px_offset + 2), ((color.0 as u32 * alpha) / 255) as u8);
                core::ptr::write(fb.wrapping_add(px_offset + 1), ((color.1 as u32 * alpha) / 255) as u8);
                core::ptr::write(fb.wrapping_add(px_offset + 0), ((color.2 as u32 * alpha) / 255) as u8);
            }
        }
    }
}

pub fn draw_text(x: u32, y: u32, size: f32, font: &spin::Once<fontdue::Font>, text: &str, fb: &crate::limine::Framebuffer) {
    let font = font.get().unwrap();

    let ascent = font.horizontal_line_metrics(size)
        .map(|m| m.ascent)
        .unwrap_or(size) as i32;

    let mut x_offset = 0i32;
    for char in text.chars() {
        let (metrics, bitmap) = font.rasterize(char, size);

        let glyph_y = y as i32 + ascent - metrics.height as i32 - metrics.ymin;
        let glyph_x = x as i32 + x_offset + metrics.xmin;

        if glyph_y >= 0 && glyph_x >= 0 {
            draw_glyph(
                fb.base,
                fb.pitch as usize,
                bitmap.as_slice(),
                metrics.width,
                metrics.height,
                glyph_x as usize,
                glyph_y as usize,
                (255, 255, 255),
            );
        }

        x_offset += metrics.advance_width as usize as i32;
    }
}