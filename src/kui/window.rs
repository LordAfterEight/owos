use crate::kui::{
    WindowContentRect, BORDER_T, PALETTE_CYAN, PALETTE_MAGENTA, TEXT_INSET_X, TEXT_INSET_Y,
    TITLE_BAR_BORDER, TITLE_BAR_H, TITLE_FONT_SIZE, WINDOW_BG_ALPHA,
};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub struct WindowHandle(pub u32);

#[derive(Clone, Copy, Debug)]
pub struct FrameRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

#[derive(Debug)]
pub enum WindowError {
    NotFound,
    NotOwner,
    InvalidFrame,
}

#[derive(Debug)]
pub enum WindowDrawError {
    NotFound,
    NotOwner,
}

struct ContentBuffer {
    pixels: alloc::vec::Vec<u8>,
    width: u32,
    height: u32,
    stride: usize,
    bpp: usize,
}

struct FrostCache {
    pixels: alloc::vec::Vec<u8>,
    w: u32,
    h: u32,
}

struct Window {
    owner_pid: u32,
    title: alloc::string::String,
    frame: FrameRect,
    content: ContentBuffer,
    dirty: bool,
    frost_title: Option<FrostCache>,
    frost_content: Option<FrostCache>,
}

pub struct WindowManager {
    windows: alloc::collections::BTreeMap<u32, Window>,
    z_order: alloc::vec::Vec<WindowHandle>,
    next_id: u32,
    focused: Option<WindowHandle>,
    cursor_dirty: bool,
}

impl WindowManager {
    pub const fn new() -> Self {
        Self {
            windows: alloc::collections::BTreeMap::new(),
            z_order: alloc::vec::Vec::new(),
            next_id: 1,
            focused: None,
            cursor_dirty: false,
        }
    }

    pub fn screen_content_rect(frame: &FrameRect) -> WindowContentRect {
        let border = BORDER_T as u32;
        WindowContentRect {
            x: frame.x + border,
            y: frame.y + TITLE_BAR_H + border,
            w: frame.w.saturating_sub(border * 2),
            h: frame.h.saturating_sub(TITLE_BAR_H + border * 2),
        }
    }

    pub fn local_content_rect(frame: &FrameRect) -> WindowContentRect {
        let screen = Self::screen_content_rect(frame);
        WindowContentRect {
            x: 0,
            y: 0,
            w: screen.w,
            h: screen.h,
        }
    }

    pub fn frame_size_for_content(content_w: u32, content_h: u32) -> (u32, u32) {
        let border = BORDER_T as u32;
        (
            content_w + border * 2,
            TITLE_BAR_H + border * 2 + content_h,
        )
    }

    fn invalidate_all_frost(&mut self) {
        for window in self.windows.values_mut() {
            window.frost_title = None;
            window.frost_content = None;
        }
    }

    pub fn create(
        &mut self,
        owner_pid: u32,
        title: alloc::string::String,
        frame: FrameRect,
    ) -> Result<(WindowHandle, WindowContentRect), WindowError> {
        let border = BORDER_T as u32;
        if frame.w < border * 2 + 8
            || frame.h < TITLE_BAR_H + border * 2 + 4
        {
            return Err(WindowError::InvalidFrame);
        }

        let local = Self::local_content_rect(&frame);
        if local.w == 0 || local.h == 0 {
            return Err(WindowError::InvalidFrame);
        }

        let bpp = crate::kui::kdraw::buffer_bpp();
        let stride = local.w as usize * bpp;
        let mut pixels = alloc::vec::Vec::new();
        pixels.resize(stride * local.h as usize, 0);

        let handle = WindowHandle(self.next_id);
        self.next_id += 1;

        self.windows.insert(
            handle.0,
            Window {
                owner_pid,
                title,
                frame,
                content: ContentBuffer {
                    pixels,
                    width: local.w,
                    height: local.h,
                    stride,
                    bpp,
                },
                dirty: true,
                frost_title: None,
                frost_content: None,
            },
        );
        self.z_order.push(handle);
        self.focus_window(handle);

        Ok((handle, local))
    }

    pub fn destroy(&mut self, handle: WindowHandle, requester_pid: u32) -> Result<(), WindowError> {
        let window = self.windows.get(&handle.0).ok_or(WindowError::NotFound)?;
        if requester_pid != 0 && window.owner_pid != requester_pid {
            return Err(WindowError::NotOwner);
        }
        self.windows.remove(&handle.0);
        self.z_order.retain(|h| *h != handle);
        if self.focused == Some(handle) {
            self.focused = self.z_order.last().copied();
        }
        self.invalidate_all_frost();
        self.mark_all_dirty();
        Ok(())
    }

    pub fn destroy_by_owner(&mut self, owner_pid: u32) {
        let handles: alloc::vec::Vec<WindowHandle> = self
            .windows
            .iter()
            .filter(|(_, window)| window.owner_pid == owner_pid)
            .map(|(id, _)| WindowHandle(*id))
            .collect();
        for handle in handles {
            let _ = self.destroy(handle, 0);
        }
    }

    pub fn raise_to_top(&mut self, handle: WindowHandle, requester_pid: u32) -> Result<(), WindowError> {
        self.reorder(handle, requester_pid, true)
    }

    pub fn lower_to_bottom(&mut self, handle: WindowHandle, requester_pid: u32) -> Result<(), WindowError> {
        self.reorder(handle, requester_pid, false)
    }

    fn reorder(&mut self, handle: WindowHandle, requester_pid: u32, to_top: bool) -> Result<(), WindowError> {
        let window = self.windows.get(&handle.0).ok_or(WindowError::NotFound)?;
        if requester_pid != 0 && window.owner_pid != requester_pid {
            return Err(WindowError::NotOwner);
        }
        self.z_order.retain(|h| *h != handle);
        if to_top {
            self.z_order.push(handle);
        } else {
            self.z_order.insert(0, handle);
        }
        self.invalidate_all_frost();
        self.mark_dirty(handle);
        Ok(())
    }

    pub fn focus_window(&mut self, handle: WindowHandle) {
        if !self.windows.contains_key(&handle.0) {
            return;
        }
        self.focused = Some(handle);
        if self.z_order.last() != Some(&handle) {
            self.raise_to_top(handle, 0).ok();
        }
    }

    pub fn focus_first_for_owner(&mut self, owner_pid: u32) {
        let handle = self
            .windows
            .iter()
            .find(|(_, window)| window.owner_pid == owner_pid)
            .map(|(id, _)| WindowHandle(*id));
        if let Some(handle) = handle {
            self.focus_window(handle);
        }
    }

    pub fn move_window(&mut self, handle: WindowHandle, x: u32, y: u32) {
        if let Some(window) = self.windows.get_mut(&handle.0) {
            window.frame.x = x;
            window.frame.y = y;
            window.dirty = true;
            window.frost_title = None;
            window.frost_content = None;
        }
    }

    fn mark_all_dirty(&mut self) {
        for window in self.windows.values_mut() {
            window.dirty = true;
        }
    }

    pub fn frame_rect(&self, handle: WindowHandle) -> Option<FrameRect> {
        self.windows.get(&handle.0).map(|w| w.frame)
    }

    pub fn window_at(&self, x: i32, y: i32) -> Option<WindowHandle> {
        for handle in self.z_order.iter().rev() {
            let Some(window) = self.windows.get(&handle.0) else {
                continue;
            };
            let f = window.frame;
            if x >= f.x as i32
                && y >= f.y as i32
                && x < (f.x + f.w) as i32
                && y < (f.y + f.h) as i32
            {
                return Some(*handle);
            }
        }
        None
    }

    pub fn focused_owner_pid(&self) -> Option<u32> {
        self.focused
            .and_then(|handle| self.windows.get(&handle.0))
            .map(|window| window.owner_pid)
    }

    pub fn is_focused(&self, handle: WindowHandle) -> bool {
        self.focused == Some(handle)
    }

    pub fn in_title_bar(&self, handle: WindowHandle, x: i32, y: i32) -> bool {
        let Some(window) = self.windows.get(&handle.0) else {
            return false;
        };
        let f = window.frame;
        x >= f.x as i32
            && y >= f.y as i32
            && x < (f.x + f.w) as i32
            && y < (f.y + TITLE_BAR_H) as i32
    }

    pub fn mark_dirty(&mut self, handle: WindowHandle) {
        if let Some(window) = self.windows.get_mut(&handle.0) {
            window.dirty = true;
        }
    }

    pub fn mark_cursor_dirty(&mut self) {
        self.cursor_dirty = true;
    }

    pub fn needs_windows_composite(&self) -> bool {
        self.windows.values().any(|w| w.dirty)
    }

    pub fn needs_cursor_composite(&self) -> bool {
        self.cursor_dirty
    }

    pub fn get_local_content_rect(&self, handle: WindowHandle) -> Option<WindowContentRect> {
        self.windows
            .get(&handle.0)
            .map(|w| Self::local_content_rect(&w.frame))
    }

    pub fn with_content_mut<R>(
        &mut self,
        handle: WindowHandle,
        owner_pid: u32,
        f: impl FnOnce(&mut [u8], usize, usize, u32, u32) -> R,
    ) -> Result<R, WindowDrawError> {
        let window = self.windows.get_mut(&handle.0).ok_or(WindowDrawError::NotFound)?;
        if owner_pid != 0 && window.owner_pid != owner_pid {
            return Err(WindowDrawError::NotOwner);
        }
        let content = &mut window.content;
        let result = f(
            &mut content.pixels,
            content.stride,
            content.bpp,
            content.width,
            content.height,
        );
        window.dirty = true;
        Ok(result)
    }

    fn paint_frost(bpp: usize, x: u32, y: u32, w: u32, h: u32, cache: &mut Option<FrostCache>) {
        if w == 0 || h == 0 {
            return;
        }
        let hit = cache.as_ref().is_some_and(|c| c.w == w && c.h == h);
        if hit {
            if let Some(frost) = cache.as_ref() {
                crate::kui::kdraw::blit_frost_region(&frost.pixels, w, h, bpp, x, y);
            }
        } else {
            let pixels = crate::kui::kdraw::build_frost_region(x, y, w, h, WINDOW_BG_ALPHA);
            *cache = Some(FrostCache { pixels, w, h });
        }
    }

    pub fn composite_windows(&mut self) {
        crate::kui::kdraw::clear_backbuffer(0);

        let handles: alloc::vec::Vec<WindowHandle> = self.z_order.clone();
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let clip = crate::kui::framebuffer_rect(fb);

        for handle in handles {
            let Some(window) = self.windows.get_mut(&handle.0) else {
                continue;
            };
            let frame = window.frame;
            let title = window.title.clone();
            let screen_content = Self::screen_content_rect(&frame);
            let chrome = PALETTE_MAGENTA;
            let title_border = TITLE_BAR_BORDER as u32;
            let title_inner_x = frame.x + title_border;
            let title_inner_y = frame.y + title_border;
            let title_inner_w = frame.w.saturating_sub(title_border * 2);
            let title_inner_h = TITLE_BAR_H.saturating_sub(title_border * 2);

            let bpp = window.content.bpp;
            Self::paint_frost(
                bpp,
                title_inner_x,
                title_inner_y,
                title_inner_w,
                title_inner_h,
                &mut window.frost_title,
            );

            crate::kui::kdraw::draw_rect(
                frame.x,
                frame.y,
                frame.w,
                TITLE_BAR_H,
                TITLE_BAR_BORDER,
                chrome,
            );

            let title_y = frame.y
                + (TITLE_BAR_H.saturating_sub(
                    crate::kui::kdraw::line_height(&crate::kui::kfont::BARCODE, TITLE_FONT_SIZE)
                        as u32,
                )) / 2;
            crate::kui::kdraw::draw_text(
                frame.x + 6,
                title_y,
                TITLE_FONT_SIZE,
                &crate::kui::kfont::BARCODE,
                &title,
                chrome,
                clip.x,
                clip.y,
                clip.w,
                clip.h,
            );

            Self::paint_frost(
                bpp,
                screen_content.x,
                screen_content.y,
                screen_content.w,
                screen_content.h,
                &mut window.frost_content,
            );

            crate::kui::kdraw::draw_rect(
                frame.x,
                frame.y + TITLE_BAR_H,
                frame.w,
                frame.h.saturating_sub(TITLE_BAR_H),
                BORDER_T,
                chrome,
            );

            let content_pixels = window.content.pixels.clone();
            let content_stride = window.content.stride;
            let content_bpp = window.content.bpp;
            let content_w = window.content.width;
            let content_h = window.content.height;
            window.dirty = false;

            crate::kui::kdraw::blit_to_backbuffer(
                &content_pixels,
                content_stride,
                content_bpp,
                content_w,
                content_h,
                screen_content.x,
                screen_content.y,
            );
        }

        crate::kui::kdraw::snapshot_backbuffer();
    }

    pub fn composite_cursor(&mut self, cursor_x: i32, cursor_y: i32, last_x: i32, last_y: i32) {
        crate::kui::kdraw::restore_backbuffer();
        if last_x >= 0 && last_y >= 0 {
            Self::mark_cursor_rect(last_x, last_y);
        }
        Self::draw_cursor(cursor_x, cursor_y);
        Self::mark_cursor_rect(cursor_x, cursor_y);
        self.cursor_dirty = false;
    }

    pub fn composite(&mut self, cursor_x: i32, cursor_y: i32) {
        self.composite_windows();
        self.composite_cursor(cursor_x, cursor_y, -1, -1);
    }

    fn mark_cursor_rect(x: i32, y: i32) {
        let cx = x.max(0) as u32;
        let cy = y.max(0) as u32;
        crate::kui::kdraw::mark_dirty_rect(cx.saturating_sub(3), cy, 11, 12);
    }

    fn draw_cursor(x: i32, y: i32) {
        let cx = x.max(0) as u32;
        let cy = y.max(0) as u32;
        crate::kui::kdraw::draw_rect_f(cx, cy, 2, 10, PALETTE_CYAN);
        crate::kui::kdraw::draw_rect_f(cx.saturating_sub(3), cy + 3, 8, 2, PALETTE_CYAN);
    }
}

pub static WINDOW_MANAGER: spin::Mutex<WindowManager> =
    spin::Mutex::new(WindowManager::new());

pub fn window_text_origin(content: &WindowContentRect) -> (u32, u32) {
    (content.x + TEXT_INSET_X, content.y + TEXT_INSET_Y)
}