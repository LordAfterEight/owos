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
static BLUR_SCRATCH: spin::Mutex<alloc::vec::Vec<u8>> = spin::Mutex::new(alloc::vec::Vec::new());
static COMPOSITE_CACHE: spin::Mutex<Option<alloc::vec::Vec<u8>>> = spin::Mutex::new(None);

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

pub(crate) fn present() {
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
    let mut width = 0.0f32;
    for char in text.chars() {
        let (metrics, _bitmap) = font.get().unwrap().rasterize(char, size);
        width += metrics.advance_width;
    }
    width as usize
}

pub(crate) fn buffer_bpp() -> usize {
    BACKBUFFER
        .lock()
        .as_ref()
        .map(|bb| bb.bpp)
        .unwrap_or_else(|| (fb().bpp / 8) as usize)
}

pub(crate) fn fill_rect(
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

pub(crate) fn draw_text_buf(
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

pub(crate) fn draw_text(
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

pub(crate) fn draw_rect_f(x: u32, y: u32, w: u32, h: u32, col: u32) {
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

fn draw_rect_buf(
    pixels: &mut [u8],
    stride: usize,
    bpp: usize,
    buf_w: u32,
    buf_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    t: u16,
    col: u32,
) {
    let t = (t as u32).max(1);
    let x_end = (x + w).min(buf_w);
    let y_end = (y + h).min(buf_h);

    let put_pixel = |pixels: &mut [u8], px: u32, py: u32| {
        if px >= buf_w || py >= buf_h {
            return;
        }
        let offset = py as usize * stride + px as usize * bpp;
        pixels[offset] = (col & 0xFF) as u8;
        pixels[offset + 1] = ((col >> 8) & 0xFF) as u8;
        pixels[offset + 2] = ((col >> 16) & 0xFF) as u8;
    };

    for row in 0..t {
        for px in x..x_end {
            put_pixel(pixels, px, y + row);
            if y + h > row {
                put_pixel(pixels, px, y + h - 1 - row);
            }
        }
    }

    for edge in 0..t {
        for py in y..y_end {
            put_pixel(pixels, x + edge, py);
            if x + w > edge {
                put_pixel(pixels, x + w - 1 - edge, py);
            }
        }
    }
}

pub(crate) fn draw_rect(x: u32, y: u32, w: u32, h: u32, t: u16, col: u32) {
    with_backbuffer(|bb| {
        draw_rect_buf(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y,
            w,
            h,
            t,
            col,
        );
        mark_dirty_rows(bb, y, h);
    });
}

pub(crate) fn clear_backbuffer(col: u32) {
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

fn sample_pixel(pixels: &[u8], stride: usize, bpp: usize, x: i32, y: i32) -> (u32, u32, u32) {
    if x < 0 || y < 0 {
        return (0, 0, 0);
    }
    let offset = y as usize * stride + x as usize * bpp;
    if offset + 2 >= pixels.len() {
        return (0, 0, 0);
    }
    (
        pixels[offset] as u32,
        pixels[offset + 1] as u32,
        pixels[offset + 2] as u32,
    )
}

fn blur_region_impl(
    pixels: &mut [u8],
    stride: usize,
    bpp: usize,
    buf_w: u32,
    buf_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) {
    if w == 0 || h == 0 {
        return;
    }
    let radius = crate::kui::BLUR_RADIUS;
    let diameter = (radius * 2 + 1) as u32;
    let region_size = w as usize * h as usize * bpp;
    let mut scratch = BLUR_SCRATCH.lock();
    if scratch.len() < region_size {
        scratch.resize(region_size, 0);
    }

    for row in 0..h {
        let py = y + row;
        if py >= buf_h {
            continue;
        }
        for col in 0..w {
            let px = x + col;
            if px >= buf_w {
                continue;
            }
            let mut b_sum = 0u32;
            let mut g_sum = 0u32;
            let mut r_sum = 0u32;
            for kx in -radius..=radius {
                let (b, g, r) = sample_pixel(
                    pixels,
                    stride,
                    bpp,
                    px as i32 + kx,
                    py as i32,
                );
                b_sum += b;
                g_sum += g;
                r_sum += r;
            }
            let out_off = row as usize * w as usize * bpp + col as usize * bpp;
            scratch[out_off] = (b_sum / diameter) as u8;
            scratch[out_off + 1] = (g_sum / diameter) as u8;
            scratch[out_off + 2] = (r_sum / diameter) as u8;
            if bpp > 3 {
                scratch[out_off + 3] = 0xFF;
            }
        }
    }

    for row in 0..h {
        let py = y + row;
        if py >= buf_h {
            continue;
        }
        for col in 0..w {
            let px = x + col;
            if px >= buf_w {
                continue;
            }
            let mut b_sum = 0u32;
            let mut g_sum = 0u32;
            let mut r_sum = 0u32;
            for ky in -radius..=radius {
                let src_row = (row as i32 + ky).clamp(0, h as i32 - 1) as u32;
                let src_off = src_row as usize * w as usize * bpp + col as usize * bpp;
                b_sum += scratch[src_off] as u32;
                g_sum += scratch[src_off + 1] as u32;
                r_sum += scratch[src_off + 2] as u32;
            }
            let dst_off = py as usize * stride + px as usize * bpp;
            pixels[dst_off] = (b_sum / diameter) as u8;
            pixels[dst_off + 1] = (g_sum / diameter) as u8;
            pixels[dst_off + 2] = (r_sum / diameter) as u8;
        }
    }
}

pub(crate) fn box_blur_region(x: u32, y: u32, w: u32, h: u32) {
    with_backbuffer(|bb| {
        let x_end = (x + w).min(bb.width);
        let y_end = (y + h).min(bb.height);
        let region_w = x_end.saturating_sub(x);
        let region_h = y_end.saturating_sub(y);
        if region_w == 0 || region_h == 0 {
            return;
        }
        blur_region_impl(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y,
            region_w,
            region_h,
        );
        mark_dirty_rows(bb, y, region_h);
    });
}

pub(crate) fn build_frost_region(x: u32, y: u32, w: u32, h: u32, alpha: u8) -> alloc::vec::Vec<u8> {
    let mut out = alloc::vec::Vec::new();
    with_backbuffer(|bb| {
        let x_end = (x + w).min(bb.width);
        let y_end = (y + h).min(bb.height);
        let region_w = x_end.saturating_sub(x);
        let region_h = y_end.saturating_sub(y);
        if region_w == 0 || region_h == 0 {
            return;
        }
        blur_region_impl(
            &mut bb.pixels,
            bb.stride,
            bb.bpp,
            bb.width,
            bb.height,
            x,
            y,
            region_w,
            region_h,
        );
        let keep = 255u32 - alpha as u32;
        for py in y..y_end {
            let row_start = py as usize * bb.stride;
            for px in x..x_end {
                let offset = row_start + px as usize * bb.bpp;
                bb.pixels[offset] = (bb.pixels[offset] as u32 * keep / 255) as u8;
                bb.pixels[offset + 1] = (bb.pixels[offset + 1] as u32 * keep / 255) as u8;
                bb.pixels[offset + 2] = (bb.pixels[offset + 2] as u32 * keep / 255) as u8;
            }
        }
        let row_bytes = region_w as usize * bb.bpp;
        out.resize(row_bytes * region_h as usize, 0);
        for row in 0..region_h {
            let src = (y + row) as usize * bb.stride + x as usize * bb.bpp;
            let dst = row as usize * row_bytes;
            out[dst..dst + row_bytes].copy_from_slice(&bb.pixels[src..src + row_bytes]);
        }
        mark_dirty_rows(bb, y, region_h);
    });
    out
}

pub(crate) fn blit_frost_region(
    pixels: &[u8],
    w: u32,
    h: u32,
    bpp: usize,
    dst_x: u32,
    dst_y: u32,
) {
    with_backbuffer(|bb| {
        let row_bytes = w as usize * bpp;
        let copy_h = h.min(bb.height.saturating_sub(dst_y));
        for row in 0..copy_h {
            let src = row as usize * row_bytes;
            let dst = (dst_y + row) as usize * bb.stride + dst_x as usize * bpp;
            let end = src + row_bytes;
            if end <= pixels.len() && dst + row_bytes <= bb.pixels.len() {
                bb.pixels[dst..dst + row_bytes].copy_from_slice(&pixels[src..end]);
            }
        }
        mark_dirty_rows(bb, dst_y, copy_h);
    });
}

pub(crate) fn snapshot_backbuffer() {
    let mut guard = BACKBUFFER.lock();
    let Some(bb) = guard.as_mut() else {
        return;
    };
    let mut cache = COMPOSITE_CACHE.lock();
    if cache.as_ref().is_none_or(|c| c.len() != bb.pixels.len()) {
        *cache = Some(alloc::vec::Vec::with_capacity(bb.pixels.len()));
    }
    if let Some(buf) = cache.as_mut() {
        buf.clear();
        buf.extend_from_slice(&bb.pixels);
    }
}

pub(crate) fn restore_backbuffer() {
    let mut guard = BACKBUFFER.lock();
    let Some(bb) = guard.as_mut() else {
        return;
    };
    let cache = COMPOSITE_CACHE.lock();
    if let Some(buf) = cache.as_ref() {
        if buf.len() == bb.pixels.len() {
            bb.pixels.copy_from_slice(buf);
        }
    }
}

pub(crate) fn mark_dirty_rect(_x: u32, y: u32, _w: u32, h: u32) {
    with_backbuffer(|bb| {
        mark_dirty_rows(bb, y, h.min(bb.height.saturating_sub(y)));
    });
}

pub(crate) fn alpha_darken_region(x: u32, y: u32, w: u32, h: u32, alpha: u8) {
    with_backbuffer(|bb| {
        if w == 0 || h == 0 {
            return;
        }

        let x_end = (x + w).min(bb.width);
        let y_end = (y + h).min(bb.height);
        let keep = 255u32 - alpha as u32;

        for py in y..y_end {
            let row_start = py as usize * bb.stride;
            for px in x..x_end {
                let offset = row_start + px as usize * bb.bpp;
                if offset + 2 >= bb.pixels.len() {
                    continue;
                }
                bb.pixels[offset] = (bb.pixels[offset] as u32 * keep / 255) as u8;
                bb.pixels[offset + 1] = (bb.pixels[offset + 1] as u32 * keep / 255) as u8;
                bb.pixels[offset + 2] = (bb.pixels[offset + 2] as u32 * keep / 255) as u8;
            }
        }

        mark_dirty_rows(bb, y, y_end.saturating_sub(y));
    });
}

pub(crate) fn blit_to_backbuffer(
    src: &[u8],
    src_stride: usize,
    bpp: usize,
    src_w: u32,
    src_h: u32,
    dst_x: u32,
    dst_y: u32,
) {
    with_backbuffer(|bb| {
        let copy_h = src_h.min(bb.height.saturating_sub(dst_y));
        let copy_w = src_w.min(bb.width.saturating_sub(dst_x));
        let row_bytes = copy_w as usize * bpp;

        for row in 0..copy_h {
            let src_off = row as usize * src_stride;
            let dst_off = (dst_y + row) as usize * bb.stride + dst_x as usize * bpp;
            let src_end = src_off + row_bytes;
            let dst_end = dst_off + row_bytes;
            if src_end <= src.len() && dst_end <= bb.pixels.len() {
                bb.pixels[dst_off..dst_end].copy_from_slice(&src[src_off..src_end]);
            }
        }

        mark_dirty_rows(bb, dst_y, copy_h);
    });
}

pub fn draw_text_in_window(
    handle: crate::kui::window::WindowHandle,
    owner_pid: u32,
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
) -> Result<(), crate::kui::window::WindowDrawError> {
    let text_h = line_height(font, size) as u32 + 1;
    crate::kui::window::WINDOW_MANAGER.lock().with_content_mut(
        handle,
        owner_pid,
        |pixels, stride, bpp, width, height| {
            draw_text_buf(
                pixels.as_mut_ptr(),
                stride,
                bpp,
                width as usize,
                height as usize,
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
        },
    )?;
    let _ = text_h;
    Ok(())
}

pub fn draw_rect_f_in_window(
    handle: crate::kui::window::WindowHandle,
    owner_pid: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    col: u32,
) -> Result<(), crate::kui::window::WindowDrawError> {
    crate::kui::window::WINDOW_MANAGER.lock().with_content_mut(
        handle,
        owner_pid,
        |pixels, stride, bpp, width, height| {
            fill_rect(pixels, stride, bpp, width, height, x, y, w, h, col);
        },
    )
}

pub fn draw_rect_in_window(
    handle: crate::kui::window::WindowHandle,
    owner_pid: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    t: u16,
    col: u32,
) -> Result<(), crate::kui::window::WindowDrawError> {
    crate::kui::window::WINDOW_MANAGER.lock().with_content_mut(
        handle,
        owner_pid,
        |pixels, stride, bpp, width, height| {
            draw_rect_buf(pixels, stride, bpp, width, height, x, y, w, h, t, col);
        },
    )
}