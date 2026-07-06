pub struct SyncFramebuffer(pub &'static crate::limine::Framebuffer);

unsafe impl Sync for SyncFramebuffer {}
unsafe impl Send for SyncFramebuffer {}

pub static GLOBAL_FB: spin::Once<SyncFramebuffer> = spin::Once::new();

struct Backbuffer {
    pixels: alloc::vec::Vec<u8>,
    width: u32,
    height: u32,
    stride: usize,
    bpp: usize,
    dirty: bool,
    dirty_y0: u32,
    dirty_y1: u32,
}

static BACKBUFFER: spin::Mutex<Option<Backbuffer>> = spin::Mutex::new(None);

/// Panics if called before GLOBAL_FB.call_once(...) has run.
fn fb() -> &'static crate::limine::Framebuffer {
    GLOBAL_FB.get().expect("GLOBAL_FB not initialized").0
}

fn with_backbuffer<R>(f: impl FnOnce(&mut Backbuffer) -> R) -> Option<R> {
    let mut guard = BACKBUFFER.lock();
    guard.as_mut().map(f)
}

pub fn init_backbuffer() {
    let fb = fb();
    let bpp = (fb.bpp / 8) as usize;
    let width = fb.width as u32;
    let height = fb.height as u32;
    let stride = width as usize * bpp;
    let mut pixels = alloc::vec::Vec::new();
    pixels.resize(stride * height as usize, 0);
    *BACKBUFFER.lock() = Some(Backbuffer {
        pixels,
        width,
        height,
        stride,
        bpp,
        dirty: false,
        dirty_y0: 0,
        dirty_y1: 0,
    });
}

fn mark_dirty_rows(bb: &mut Backbuffer, y: u32, h: u32) {
    if h == 0 {
        return;
    }
    let y1 = (y.saturating_add(h)).min(bb.height);
    let y0 = y.min(bb.height);
    if y0 >= y1 {
        return;
    }
    if !bb.dirty {
        bb.dirty_y0 = y0;
        bb.dirty_y1 = y1;
        bb.dirty = true;
    } else {
        bb.dirty_y0 = bb.dirty_y0.min(y0);
        bb.dirty_y1 = bb.dirty_y1.max(y1);
    }
}

fn mark_dirty_all(bb: &mut Backbuffer) {
    bb.dirty_y0 = 0;
    bb.dirty_y1 = bb.height;
    bb.dirty = true;
}

pub fn is_dirty() -> bool {
    BACKBUFFER.lock().as_ref().is_some_and(|bb| bb.dirty)
}

pub fn present() {
    let mut guard = BACKBUFFER.lock();
    let Some(bb) = guard.as_mut() else {
        return;
    };
    if !bb.dirty {
        return;
    }

    let fb = fb();
    let fb_stride = fb.pitch as usize;
    let row_bytes = bb.width as usize * bb.bpp;

    let y0 = bb.dirty_y0 as usize;
    let y1 = bb.dirty_y1 as usize;
    for row in y0..y1.min(bb.height as usize) {
        let src = row * bb.stride;
        let dst = row * fb_stride;
        unsafe {
            core::ptr::copy_nonoverlapping(
                bb.pixels.as_ptr().add(src),
                fb.base.wrapping_add(dst),
                row_bytes,
            );
        }
    }

    bb.dirty = false;
}

pub fn line_height(font: &spin::Once<fontdue::Font>, size: f32) -> f32 {
    font.get()
        .and_then(|f| f.horizontal_line_metrics(size))
        .map(|m| m.new_line_size)
        .unwrap_or(size * 1.2)
}

pub fn text_length(text: &str, font: &spin::Once<fontdue::Font>, size: f32) -> usize {
    let mut width = 0;
    for char in text.chars() {
        let (metrics, _bitmap) = font.get().unwrap().rasterize(char, size);
        width += metrics.advance_width as usize;
    }
    width
}

fn fill_rect(
    buf: &mut [u8],
    stride: usize,
    bpp: usize,
    buf_w: u32,
    buf_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    col: u32,
) {
    let x_end = (x + w).min(buf_w);
    let y_end = (y + h).min(buf_h);
    if col == 0 && x == 0 && x_end == buf_w {
        for py in y..y_end {
            let row_start = py as usize * stride;
            let row_end = row_start + x_end as usize * bpp;
            buf[row_start..row_end].fill(0);
        }
        return;
    }

    let b = (col & 0xFF) as u8;
    let g = ((col >> 8) & 0xFF) as u8;
    let r = ((col >> 16) & 0xFF) as u8;

    for py in y..y_end {
        let row_start = py as usize * stride;
        for px in x..x_end {
            let offset = row_start + px as usize * bpp;
            buf[offset] = b;
            buf[offset + 1] = g;
            buf[offset + 2] = r;
            if bpp > 3 {
                buf[offset + 3] = 0xFF;
            }
        }
    }
}

fn draw_glyph(
    buf: *mut u8,
    stride: usize,
    bpp: usize,
    clip_left: usize,
    clip_top: usize,
    clip_right: usize,
    clip_bottom: usize,
    bitmap: &[u8],
    glyph_w: usize,
    glyph_h: usize,
    x: usize,
    y: usize,
    color: (u8, u8, u8),
) {
    for row in 0..glyph_h {
        let py = y + row;
        if py < clip_top || py >= clip_bottom {
            continue;
        }
        for col in 0..glyph_w {
            let px = x + col;
            if px < clip_left || px >= clip_right {
                continue;
            }

            let coverage = bitmap[row * glyph_w + col];
            if coverage == 0 {
                continue;
            }

            let px_offset = py * stride + px * bpp;
            let alpha = coverage as u32;
            unsafe {
                core::ptr::write(
                    buf.wrapping_add(px_offset + 2),
                    ((color.0 as u32 * alpha) / 255) as u8,
                );
                core::ptr::write(
                    buf.wrapping_add(px_offset + 1),
                    ((color.1 as u32 * alpha) / 255) as u8,
                );
                core::ptr::write(
                    buf.wrapping_add(px_offset),
                    ((color.2 as u32 * alpha) / 255) as u8,
                );
            }
        }
    }
}

fn draw_text_buf(
    buf: *mut u8,
    stride: usize,
    bpp: usize,
    buf_width: usize,
    buf_height: usize,
    clip_x: u32,
    clip_y: u32,
    clip_w: u32,
    clip_h: u32,
    x: u32,
    y: u32,
    size: f32,
    font: &spin::Once<fontdue::Font>,
    text: &str,
    color: u32,
) {
    let font = font.get().unwrap();
    let clip_left = clip_x as usize;
    let clip_top = clip_y as usize;
    let clip_right = (clip_x.saturating_add(clip_w)).min(buf_width as u32) as usize;
    let clip_bottom = (clip_y.saturating_add(clip_h)).min(buf_height as u32) as usize;

    let line_metrics = font.horizontal_line_metrics(size);
    let line_height = line_metrics.map(|m| m.new_line_size).unwrap_or(size * 1.2);
    let ascent = line_metrics.map(|m| m.ascent).unwrap_or(size);

    let mut x_offset = 0.0f32;
    let mut line = 0u32;
    for char in text.chars() {
        if char == '\n' {
            line += 1;
            x_offset = 0.0;
            continue;
        }

        let (metrics, bitmap) = font.rasterize(char, size);
        let glyph_x = x as f32 + x_offset + metrics.xmin as f32;
        let glyph_y = y as f32 + line as f32 * line_height + ascent
            - metrics.height as f32
            - metrics.ymin as f32;

        if glyph_x >= 0.0 && glyph_y >= 0.0 {
            draw_glyph(
                buf,
                stride,
                bpp,
                clip_left,
                clip_top,
                clip_right,
                clip_bottom,
                bitmap.as_slice(),
                metrics.width,
                metrics.height,
                glyph_x as usize,
                glyph_y as usize,
                (
                    (color >> 16 & 0xFF) as u8,
                    ((color >> 8) & 0xFF) as u8,
                    (color & 0xFF) as u8,
                ),
            );
        }

        x_offset += metrics.advance_width;
    }
}

pub fn draw_text(
    x: u32,
    y: u32,
    size: f32,
    font: &spin::Once<fontdue::Font>,
    text: &str,
    color: u32,
    clip_x: u32,
    clip_y: u32,
    clip_w: u32,
    clip_h: u32,
) {
    let text_h = line_height(font, size) as u32 + 1;
    with_backbuffer(|bb| {
        draw_text_buf(
            bb.pixels.as_mut_ptr(),
            bb.stride,
            bb.bpp,
            bb.width as usize,
            bb.height as usize,
            clip_x,
            clip_y,
            clip_w,
            clip_h,
            x,
            y,
            size,
            font,
            text,
            color,
        );
        mark_dirty_rows(bb, y, text_h);
    });
}

pub fn draw_rect_f(x: u32, y: u32, w: u32, h: u32, col: u32) {
    with_backbuffer(|bb| {
        fill_rect(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y,
            w,
            h,
            col,
        );
        mark_dirty_rows(bb, y, h);
    });
}

/// Scroll a rectangle up by `dy` pixels; bottom `dy` rows are cleared to black.
pub fn scroll_rect_up(x: u32, y: u32, w: u32, h: u32, dy: u32) {
    with_backbuffer(|bb| {
        let dy = dy.min(h);
        if dy == 0 || w == 0 || h == 0 {
            return;
        }

        let row_bytes = w as usize * bb.bpp;
        let x_off = x as usize * bb.bpp;
        let copy_rows = (h - dy) as usize;
        let pixels = bb.pixels.as_mut_ptr();

        for row in (0..copy_rows).rev() {
            let src = ((y + dy + row as u32) as usize) * bb.stride + x_off;
            let dst = ((y + row as u32) as usize) * bb.stride + x_off;
            unsafe {
                core::ptr::copy(
                    pixels.wrapping_add(src),
                    pixels.wrapping_add(dst),
                    row_bytes,
                );
            }
        }

        fill_rect(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y + h - dy,
            w,
            dy,
            0,
        );
        mark_dirty_rows(bb, y, h);
    });
}

/// Scroll a rectangle down by `dy` pixels; top `dy` rows are cleared to black.
pub fn scroll_rect_down(x: u32, y: u32, w: u32, h: u32, dy: u32) {
    with_backbuffer(|bb| {
        let dy = dy.min(h);
        if dy == 0 || w == 0 || h == 0 {
            return;
        }

        let row_bytes = w as usize * bb.bpp;
        let x_off = x as usize * bb.bpp;
        let copy_rows = (h - dy) as usize;
        let pixels = bb.pixels.as_mut_ptr();

        for row in 0..copy_rows {
            let src = ((y + row as u32) as usize) * bb.stride + x_off;
            let dst = ((y + dy + row as u32) as usize) * bb.stride + x_off;
            unsafe {
                core::ptr::copy(
                    pixels.wrapping_add(src),
                    pixels.wrapping_add(dst),
                    row_bytes,
                );
            }
        }

        fill_rect(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y,
            w,
            dy,
            0,
        );
        mark_dirty_rows(bb, y, h);
    });
}

pub fn draw_rect(x: u32, y: u32, w: u32, h: u32, t: u16, col: u32) {
    with_backbuffer(|bb| {
        let bpp = bb.bpp;
        let t = (t as u32).max(1);
        let x_end = (x + w).min(bb.width);
        let y_end = (y + h).min(bb.height);

        let put_pixel = |pixels: &mut [u8], px: u32, py: u32| {
            if px >= bb.width || py >= bb.height {
                return;
            }
            let offset = py as usize * bb.stride + px as usize * bpp;
            pixels[offset] = (col & 0xFF) as u8;
            pixels[offset + 1] = ((col >> 8) & 0xFF) as u8;
            pixels[offset + 2] = ((col >> 16) & 0xFF) as u8;
        };

        for row in 0..t {
            for px in x..x_end {
                put_pixel(&mut bb.pixels, px, y + row);
                if y + h > row {
                    put_pixel(&mut bb.pixels, px, y + h - 1 - row);
                }
            }
        }

        for edge in 0..t {
            for py in y..y_end {
                put_pixel(&mut bb.pixels, x + edge, py);
                if x + w > edge {
                    put_pixel(&mut bb.pixels, x + w - 1 - edge, py);
                }
            }
        }
        mark_dirty_rows(bb, y, h);
    });
}

pub fn clear_backbuffer(col: u32) {
    with_backbuffer(|bb| {
        fill_rect(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            0,
            0,
            bb.width,
            bb.height,
            col,
        );
        mark_dirty_all(bb);
    });
}