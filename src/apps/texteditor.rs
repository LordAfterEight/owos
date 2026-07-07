use crate::ofs::{FLAG_READ, FLAG_WRTE};

#[derive(PartialEq)]
enum EditorMode {
    Edit,
    Command,
}

pub struct TextEditor {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    file_name: Option<alloc::string::String>,
    blocks: alloc::vec::Vec<alloc::vec::Vec<u8>>,
    current_block: usize,
    buffer: alloc::vec::Vec<char>,
    cursor_row: usize,
    cursor_col: usize,
    scroll_row: usize,
    dirty: bool,

    mode: EditorMode,
    command_buffer: alloc::vec::Vec<char>,
    status_message: alloc::string::String,

    cursor_visible: bool,
    cursor_blink_last: u64,
    needs_initial_draw: bool,
    needs_window: bool,
    pending_open: Option<alloc::string::String>,
    window: Option<crate::kui::WindowHandle>,
    content: Option<crate::kui::WindowContentRect>,
}

impl TextEditor {
    const FONT_SIZE: f32 = 16.0;
    const TAB_WIDTH: usize = 4;
    const STATUS_BAR_LINES: u32 = 1;
    const TEXT_COLOR: u32 = crate::kui::PALETTE_LIGHT_CYAN;
    const STATUS_COLOR: u32 = crate::kui::PALETTE_MUTED;
    const COMMAND_COLOR: u32 = crate::kui::PALETTE_AMBER;
    const CURSOR_BLINK_TICKS: u64 = 25;

    fn font() -> &'static spin::Once<fontdue::Font> {
        &crate::kui::kfont::KODEMONO_REGULAR
    }

    fn line_height() -> u32 {
        crate::kui::kdraw::line_height(Self::font(), Self::FONT_SIZE) as u32
    }

    fn lines(&self) -> alloc::vec::Vec<alloc::string::String> {
        if self.buffer.is_empty() {
            return alloc::vec![alloc::string::String::new()];
        }
        let text = alloc::string::String::from_iter(self.buffer.iter().copied());
        let mut out = alloc::vec::Vec::new();
        for line in text.split('\n') {
            out.push(Self::expand_tabs(line));
        }
        if self.buffer.last() == Some(&'\n') {
            out.push(alloc::string::String::new());
        }
        out
    }

    fn expand_tabs(text: &str) -> alloc::string::String {
        let mut out = alloc::string::String::new();
        let mut col = 0usize;
        for c in text.chars() {
            if c == '\t' {
                let spaces = Self::TAB_WIDTH - (col % Self::TAB_WIDTH);
                for _ in 0..spaces {
                    out.push(' ');
                }
                col += spaces;
            } else {
                out.push(c);
                col += 1;
            }
        }
        out
    }

    fn editor_visible_rows(&self) -> usize {
        let Some(content) = self.content else {
            return 1;
        };
        let line_h = Self::line_height().max(1);
        let status_h = line_h * Self::STATUS_BAR_LINES;
        let (_, text_y) = crate::kui::window_text_origin(&content);
        let bottom = content.y.saturating_add(content.h);
        let available = bottom.saturating_sub(text_y).saturating_sub(status_h);
        (available / line_h).max(1) as usize
    }

    fn clamp_cursor(&mut self) {
        let lines = self.lines();
        if self.cursor_row >= lines.len() {
            self.cursor_row = lines.len().saturating_sub(1);
        }
        let line_len = lines[self.cursor_row].chars().count();
        if self.cursor_col > line_len {
            self.cursor_col = line_len;
        }
    }

    fn clamp_scroll(&mut self) {
        let lines = self.lines();
        let visible = self.editor_visible_rows();
        if self.cursor_row < self.scroll_row {
            self.scroll_row = self.cursor_row;
        } else if self.cursor_row >= self.scroll_row + visible {
            self.scroll_row = self.cursor_row + 1 - visible;
        }
        let max_scroll = lines.len().saturating_sub(visible);
        if self.scroll_row > max_scroll {
            self.scroll_row = max_scroll;
        }
    }

    fn cursor_char_index(&self) -> usize {
        let mut index = 0usize;
        let mut row = 0usize;
        let mut col = 0usize;
        while row < self.cursor_row || (row == self.cursor_row && col < self.cursor_col) {
            if index >= self.buffer.len() {
                break;
            }
            if self.buffer[index] == '\n' {
                row += 1;
                col = 0;
            } else {
                col += 1;
            }
            index += 1;
        }
        index
    }

    fn set_cursor_from_index(&mut self, index: usize) {
        let index = index.min(self.buffer.len());
        let mut row = 0usize;
        let mut col = 0usize;
        for (i, c) in self.buffer.iter().enumerate() {
            if i == index {
                self.cursor_row = row;
                self.cursor_col = col;
                return;
            }
            if *c == '\n' {
                row += 1;
                col = 0;
            } else {
                col += 1;
            }
        }
        self.cursor_row = row;
        self.cursor_col = col;
    }

    fn insert_char(&mut self, c: char) {
        let index = self.cursor_char_index();
        self.buffer.insert(index, c);
        if c == '\n' {
            self.cursor_row += 1;
            self.cursor_col = 0;
        } else {
            self.cursor_col += 1;
        }
        self.dirty = true;
        self.clamp_cursor();
        self.clamp_scroll();
    }

    fn delete_before_cursor(&mut self) {
        let index = self.cursor_char_index();
        if index == 0 {
            return;
        }
        self.buffer.remove(index - 1);
        self.set_cursor_from_index(index - 1);
        self.dirty = true;
        self.clamp_cursor();
        self.clamp_scroll();
    }

    fn move_left(&mut self) {
        if self.cursor_col > 0 {
            self.cursor_col -= 1;
        } else if self.cursor_row > 0 {
            self.cursor_row -= 1;
            self.cursor_col = self.lines()[self.cursor_row].chars().count();
        }
        self.clamp_scroll();
    }

    fn move_right(&mut self) {
        let line_len = self.lines()[self.cursor_row].chars().count();
        if self.cursor_col < line_len {
            self.cursor_col += 1;
        } else if self.cursor_row + 1 < self.lines().len() {
            self.cursor_row += 1;
            self.cursor_col = 0;
        }
        self.clamp_scroll();
    }

    fn move_up(&mut self) {
        if self.cursor_row > 0 {
            self.cursor_row -= 1;
            self.clamp_cursor();
            self.clamp_scroll();
        }
    }

    fn move_down(&mut self) {
        if self.cursor_row + 1 < self.lines().len() {
            self.cursor_row += 1;
            self.clamp_cursor();
            self.clamp_scroll();
        }
    }

    fn sync_buffer_to_block(&mut self) {
        if !self.dirty {
            return;
        }
        let bytes = alloc::string::String::from_iter(self.buffer.iter().copied()).into_bytes();
        if self.current_block < self.blocks.len() {
            self.blocks[self.current_block] = bytes;
        } else {
            self.blocks.push(bytes);
        }
        self.dirty = false;
    }

    fn load_block_into_buffer(&mut self, block: usize) {
        let bytes = self
            .blocks
            .get(block)
            .cloned()
            .unwrap_or_default();
        self.buffer = alloc::string::String::from_utf8_lossy(&bytes).chars().collect();
        self.current_block = block;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_row = 0;
        self.dirty = false;
    }

    fn switch_block(&mut self, block: usize) -> Result<(), alloc::string::String> {
        self.sync_buffer_to_block();
        if block >= self.blocks.len() {
            if self.file_name.is_some() {
                self.blocks.push(alloc::vec::Vec::new());
            } else {
                return Err(alloc::string::String::from(
                    "error: no file open; use new <name.ext> first",
                ));
            }
        }
        self.load_block_into_buffer(block);
        Ok(())
    }

    fn next_block(&mut self) -> Result<(), alloc::string::String> {
        let target = if self.current_block + 1 < self.blocks.len() {
            self.current_block + 1
        } else if self.file_name.is_some() {
            self.blocks.len()
        } else {
            return Err(alloc::string::String::from(
                "error: already at last block",
            ));
        };
        self.switch_block(target)
    }

    fn prev_block(&mut self) -> Result<(), alloc::string::String> {
        if self.current_block == 0 {
            return Err(alloc::string::String::from(
                "error: already at first block",
            ));
        }
        self.switch_block(self.current_block - 1)
    }

    fn open_file(&mut self, name: &str) -> alloc::string::String {
        self.sync_buffer_to_block();
        match crate::ofs::vfs::read_blocks(name) {
            Ok(blocks) => {
                self.file_name = Some(alloc::string::String::from(name));
                self.blocks = blocks;
                if self.blocks.is_empty() {
                    self.blocks.push(alloc::vec::Vec::new());
                }
                self.load_block_into_buffer(0);
                alloc::format!("ok: opened {name}")
            }
            Err(err) => err,
        }
    }

    fn new_file(&mut self, name: &str) -> alloc::string::String {
        if !name.contains('.') {
            return alloc::string::String::from("error: file name must include an extension");
        }
        self.sync_buffer_to_block();
        match crate::ofs::vfs::ensure_file(name, FLAG_READ | FLAG_WRTE) {
            Ok(()) => {
                self.file_name = Some(alloc::string::String::from(name));
                self.blocks = alloc::vec![alloc::vec::Vec::new()];
                self.load_block_into_buffer(0);
                self.dirty = false;
                alloc::format!("ok: created {name}")
            }
            Err(err) => err,
        }
    }

    fn save_file(&mut self) -> alloc::string::String {
        let Some(name) = self.file_name.clone() else {
            return alloc::string::String::from(
                "error: no file name; use new <name.ext> or open <name.ext>",
            );
        };
        self.sync_buffer_to_block();
        let block_refs: alloc::vec::Vec<&[u8]> =
            self.blocks.iter().map(|b| b.as_slice()).collect();
        match crate::ofs::vfs::replace_blocks(&name, &block_refs, FLAG_READ | FLAG_WRTE) {
            Ok(msg) => msg,
            Err(err) => err,
        }
    }

    fn status_text(&self) -> alloc::string::String {
        let file = self
            .file_name
            .as_deref()
            .unwrap_or("untitled");
        let block_total = self.blocks.len().max(1);
        let dirty = if self.dirty { " | modified" } else { "" };
        let block = alloc::format!(
            "Block {}/{}",
            self.current_block + 1,
            block_total
        );
        if self.mode == EditorMode::Command {
            let cmd = alloc::string::String::from_iter(self.command_buffer.iter().copied());
            alloc::format!(":{cmd}_ | {file} | {block}{dirty}")
        } else if !self.status_message.is_empty() {
            alloc::format!("{} | {file} | {block}{dirty}", self.status_message)
        } else {
            alloc::format!("{file} | {block}{dirty} | Esc: command | F1/F2: block | F3: save")
        }
    }

    fn execute_command(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            self.status_message.clear();
            return;
        }
        let mut parts = line.split_whitespace();
        let cmd = parts.next().unwrap_or("");
        let rest: alloc::vec::Vec<&str> = parts.collect();
        self.status_message = match cmd {
            "open" => match rest.first() {
                Some(name) => self.open_file(name),
                None => alloc::string::String::from("error: usage open <name.ext>"),
            },
            "new" => match rest.first() {
                Some(name) => self.new_file(name),
                None => alloc::string::String::from("error: usage new <name.ext>"),
            },
            "save" => self.save_file(),
            "block" => {
                if rest.first() == Some(&"+") {
                    match self.next_block() {
                        Ok(()) => alloc::format!("ok: block {}", self.current_block + 1),
                        Err(err) => err,
                    }
                } else if rest.first() == Some(&"-") {
                    match self.prev_block() {
                        Ok(()) => alloc::format!("ok: block {}", self.current_block + 1),
                        Err(err) => err,
                    }
                } else if let Some(idx) = rest.first().and_then(|s| s.parse::<usize>().ok()) {
                    if idx == 0 {
                        alloc::string::String::from("error: block index is 1-based")
                    } else {
                        match self.switch_block(idx - 1) {
                            Ok(()) => alloc::format!("ok: block {}", self.current_block + 1),
                            Err(err) => err,
                        }
                    }
                } else {
                    alloc::string::String::from(
                        "error: usage block <n> | block + | block -",
                    )
                }
            }
            "help" => alloc::string::String::from(
                "commands: open, new, save, block, help",
            ),
            _ => alloc::format!("error: unknown command: {cmd}"),
        };
    }

    fn is_focused(&self) -> bool {
        let Some(handle) = self.window else {
            return false;
        };
        crate::kui::window::WINDOW_MANAGER.lock().is_focused(handle)
    }

    fn show_cursor(&mut self) {
        self.cursor_visible = true;
        self.cursor_blink_last = crate::time::monotonic_ms();
    }

    fn redraw(&mut self) {
        let Some(content) = self.content else {
            return;
        };
        let Some(handle) = self.window else {
            return;
        };

        let (text_x, text_y) = crate::kui::window_text_origin(&content);
        let line_h = Self::line_height();
        let visible_rows = self.editor_visible_rows();
        let status_y = text_y + visible_rows as u32 * line_h;

        let _ = crate::kui::draw_rect_f_in_window(
            handle,
            self.pid,
            content.x,
            content.y,
            content.w,
            content.h,
            0x000000,
        );

        let lines = self.lines();
        for (slot, row) in (self.scroll_row..self.scroll_row + visible_rows).enumerate() {
            let y = text_y + slot as u32 * line_h;
            if row < lines.len() {
                let _ = crate::kui::draw_text_in_window(
                    handle,
                    self.pid,
                    text_x,
                    y,
                    Self::FONT_SIZE,
                    Self::font(),
                    &lines[row],
                    Self::TEXT_COLOR,
                    content.x,
                    content.y,
                    content.w,
                    content.h,
                );
            }
        }

        if self.mode == EditorMode::Edit && self.is_focused() && self.cursor_visible {
            let cursor_row = self.cursor_row.saturating_sub(self.scroll_row);
            if cursor_row < visible_rows {
                let y = text_y + cursor_row as u32 * line_h;
                let line = lines.get(self.cursor_row).map(|s| s.as_str()).unwrap_or("");
                let before: alloc::string::String = line.chars().take(self.cursor_col).collect();
                let cursor_x = text_x
                    + crate::kui::kdraw::text_length(&before, Self::font(), Self::FONT_SIZE) as u32;
                let cursor_h = line_h.saturating_sub(4).max(4);
                let _ = crate::kui::draw_rect_f_in_window(
                    handle,
                    self.pid,
                    cursor_x,
                    y + 2,
                    2,
                    cursor_h,
                    Self::TEXT_COLOR,
                );
            }
        }

        let status = self.status_text();
        let status_color = if self.mode == EditorMode::Command {
            Self::COMMAND_COLOR
        } else {
            Self::STATUS_COLOR
        };
        let _ = crate::kui::draw_rect_f_in_window(
            handle,
            self.pid,
            content.x,
            status_y,
            content.w,
            line_h,
            0x101010,
        );
        let _ = crate::kui::draw_text_in_window(
            handle,
            self.pid,
            text_x,
            status_y,
            Self::FONT_SIZE,
            Self::font(),
            &status,
            status_color,
            content.x,
            content.y,
            content.w,
            content.h,
        );
    }

    fn handle_edit_key(&mut self, c: char) {
        match c {
            '\x1b' => {
                self.mode = EditorMode::Command;
                self.command_buffer.clear();
            }
            crate::drivers::ps2::KEY_F1 => {
                if let Err(err) = self.prev_block() {
                    self.status_message = err;
                } else {
                    self.status_message =
                        alloc::format!("ok: block {}", self.current_block + 1);
                }
            }
            crate::drivers::ps2::KEY_F2 => {
                if let Err(err) = self.next_block() {
                    self.status_message = err;
                } else {
                    self.status_message =
                        alloc::format!("ok: block {}", self.current_block + 1);
                }
            }
            crate::drivers::ps2::KEY_F3 => {
                self.status_message = self.save_file();
            }
            crate::drivers::ps2::KEY_UP => self.move_up(),
            crate::drivers::ps2::KEY_DOWN => self.move_down(),
            crate::drivers::ps2::KEY_LEFT => self.move_left(),
            crate::drivers::ps2::KEY_RIGHT => self.move_right(),
            crate::drivers::ps2::KEY_SHIFT_UP => {
                if self.scroll_row > 0 {
                    self.scroll_row -= 1;
                }
            }
            crate::drivers::ps2::KEY_SHIFT_DOWN => {
                let max = self.lines().len().saturating_sub(self.editor_visible_rows());
                if self.scroll_row < max {
                    self.scroll_row += 1;
                }
            }
            '\n' => self.insert_char('\n'),
            '\x08' => self.delete_before_cursor(),
            '\t' => self.insert_char('\t'),
            c if !c.is_control() => self.insert_char(c),
            _ => {}
        }
    }

    fn handle_command_key(&mut self, c: char) {
        match c {
            '\x1b' => {
                self.mode = EditorMode::Edit;
                self.command_buffer.clear();
            }
            '\n' => {
                let line = alloc::string::String::from_iter(self.command_buffer.drain(..));
                self.mode = EditorMode::Edit;
                self.execute_command(&line);
            }
            '\x08' => {
                self.command_buffer.pop();
            }
            c if !c.is_control() => self.command_buffer.push(c),
            _ => {}
        }
    }
}

impl crate::proc::Process for TextEditor {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Text Editor",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
            file_name: None,
            blocks: alloc::vec![alloc::vec::Vec::new()],
            current_block: 0,
            buffer: alloc::vec::Vec::new(),
            cursor_row: 0,
            cursor_col: 0,
            scroll_row: 0,
            dirty: false,
            mode: EditorMode::Edit,
            command_buffer: alloc::vec::Vec::new(),
            status_message: alloc::string::String::new(),
            cursor_visible: true,
            cursor_blink_last: 0,
            needs_initial_draw: true,
            needs_window: true,
            pending_open: None,
            window: None,
            content: None,
        })
    }

    fn name(&self) -> &'static str {
        self.name
    }

    fn pid(&self) -> u32 {
        self.pid
    }

    fn status(&self) -> crate::proc::ProcessStatus {
        self.status
    }

    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }

    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }

    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status;
    }

    fn apply_spawn_args(&mut self, args: &[alloc::string::String]) {
        if let Some(path) = args.first() {
            self.pending_open = Some(path.clone());
        }
    }

    fn on_init(&self) {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let mut frame = crate::kui::default_shell_frame(fb);
        frame.x = frame.x.saturating_add(40);
        frame.y = frame.y.saturating_add(40);
        frame.w = frame.w.saturating_sub(80);
        frame.h = frame.h.saturating_sub(80);
        crate::kui::compositor_ipc::request(
            self.pid,
            crate::kui::compositor_ipc::CompositorRequest::CreateWindow {
                owner_pid: self.pid,
                title: alloc::string::String::from("Editor"),
                x: frame.x,
                y: frame.y,
                w: frame.w,
                h: frame.h,
            },
        );
        if let Some(ps2_pid) = crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .find(|entry| entry.name == "PS/2 Driver")
            .map(|entry| entry.pid)
        {
            crate::proc::create_binding_task(self.pid, ps2_pid);
        }
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if self.needs_window {
            return Ok(crate::proc::ProcessEvent::Yielded);
        }
        if let Some(path) = self.pending_open.take() {
            self.status_message = self.open_file(&path);
            self.needs_initial_draw = true;
        }
        if self.needs_initial_draw {
            self.needs_initial_draw = false;
            self.redraw();
        }
        if self.mode == EditorMode::Edit && self.is_focused() {
            let now = crate::time::monotonic_ms();
            if now.saturating_sub(self.cursor_blink_last) >= Self::CURSOR_BLINK_TICKS {
                self.cursor_blink_last = now;
                self.cursor_visible = !self.cursor_visible;
                self.redraw();
            }
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {}

    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        match data {
            crate::proc::IpcData::SendConfirmation(msg) => {
                if let Some(crate::kui::compositor_ipc::CompositorReply::WindowCreated {
                    handle,
                    content,
                }) = crate::kui::compositor_ipc::parse_reply(&msg)
                {
                    self.window = Some(handle);
                    self.content = Some(content);
                    self.needs_window = false;
                    self.needs_initial_draw = true;
                    crate::kui::compositor_ipc::request(
                        self.pid,
                        crate::kui::compositor_ipc::CompositorRequest::FocusWindow {
                            requester_pid: self.pid,
                            handle,
                        },
                    );
                }
            }
            crate::proc::IpcData::Payload(payload) => {
                if self.window.is_none() {
                    return Ok(());
                }
                let c = payload.downcast::<char>().unwrap();
                match self.mode {
                    EditorMode::Edit => self.handle_edit_key(*c),
                    EditorMode::Command => self.handle_command_key(*c),
                }
                self.show_cursor();
                self.redraw();
            }
            _ => {}
        }
        Ok(())
    }

    fn bind(&mut self, _subscriber: u32) {}
}