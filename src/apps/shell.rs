// ! NOTE:
// This code was almost entirely written by Grok Build Beta, on 06.07.2026.
// This was more a test of the tools capabilities and will be replaced by my own implementation in the future.
// For now, it is fine for testing and debugging.

#[derive(Clone, Copy, PartialEq)]
enum ShellLineKind {
    Input,
    Output,
}

struct ShellLine {
    kind: ShellLineKind,
    text: alloc::string::String,
}

pub struct Shell {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    input_buffer: alloc::vec::Vec<char>,
    lines: alloc::collections::VecDeque<ShellLine>,
    history: alloc::collections::VecDeque<alloc::string::String>,
    scroll_offset: usize,
    history_index: Option<usize>,
    history_draft: alloc::vec::Vec<char>,
    prompt_width: u32,
    cursor_visible: bool,
    cursor_blink_last: u64,
    needs_initial_draw: bool,
    needs_window: bool,
    window: Option<crate::kui::WindowHandle>,
    content: Option<crate::kui::WindowContentRect>,
    held_allocs: alloc::vec::Vec<alloc::vec::Vec<u8>>,
}

impl crate::proc::Process for Shell {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Shell",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            input_buffer: alloc::vec::Vec::new(),
            lines: alloc::collections::VecDeque::new(),
            history: alloc::collections::VecDeque::new(),
            scroll_offset: 0,
            history_index: None,
            history_draft: alloc::vec::Vec::new(),
            prompt_width: 0,
            cursor_visible: true,
            cursor_blink_last: 0,
            needs_initial_draw: true,
            needs_window: true,
            window: None,
            content: None,
            held_allocs: alloc::vec::Vec::new(),
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
        self.name = name
    }
    fn set_pid(&mut self, pid: u32) {
        self.pid = pid
    }
    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status
    }
    fn on_init(&self) {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let frame = crate::kui::default_shell_frame(fb);
        crate::kui::compositor_ipc::request(
            self.pid,
            crate::kui::compositor_ipc::CompositorRequest::CreateWindow {
                owner_pid: self.pid,
                title: alloc::string::String::from("Shell"),
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
        if self.needs_initial_draw {
            self.needs_initial_draw = false;
            self.redraw(RedrawScope::Full);
        }
        if self.is_input_focused() {
            let now = crate::time::monotonic_ms();
            if now.saturating_sub(self.cursor_blink_last) >= Self::CURSOR_BLINK_TICKS {
                self.cursor_blink_last = now;
                self.cursor_visible = !self.cursor_visible;
                self.redraw(RedrawScope::InputLine);
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
                } else if !crate::kui::compositor_ipc::is_compositor_reply(&msg) {
                    self.push_ofs_response(msg);
                    self.redraw(RedrawScope::Full);
                }
            }
            crate::proc::IpcData::SendError(err) => {
                self.push_output(alloc::format!("ipc error: {err}"));
                self.redraw(RedrawScope::Full);
            }
            crate::proc::IpcData::Payload(payload) => {
                if payload.is::<crate::runtime::RunComplete>() {
                    let result = payload
                        .downcast::<crate::runtime::RunComplete>()
                        .unwrap();
                    if let Some(err) = &result.error {
                        self.push_output(err.clone());
                    } else {
                        if !result.output.is_empty() {
                            for line in result.output.lines() {
                                self.push_output(alloc::string::String::from(line));
                            }
                        }
                        self.push_output(alloc::format!("exit code: {}", result.exit_code));
                    }
                    self.redraw(RedrawScope::Full);
                    return Ok(());
                }

                if payload.is::<crate::arch::faults::FaultReport>() {
                    let report = payload
                        .downcast::<crate::arch::faults::FaultReport>()
                        .unwrap();
                    if let (Some(addr), Some(code)) = (report.fault_addr, report.error_code) {
                        self.push_output(alloc::format!(
                            "[fault] {} at rip={:#x} addr={:#x} err={:#x}",
                            report.name,
                            report.rip,
                            addr,
                            code
                        ));
                    } else if let Some(code) = report.error_code {
                        self.push_output(alloc::format!(
                            "[fault] {} at rip={:#x} err={:#x}",
                            report.name,
                            report.rip,
                            code
                        ));
                    } else if let Some(addr) = report.fault_addr {
                        self.push_output(alloc::format!(
                            "[fault] {} at rip={:#x} addr={:#x}",
                            report.name,
                            report.rip,
                            addr
                        ));
                    } else {
                        self.push_output(alloc::format!(
                            "[fault] {} at rip={:#x}",
                            report.name,
                            report.rip
                        ));
                    }
                    self.redraw(RedrawScope::Full);
                    return Ok(());
                }

                if self.window.is_none() {
                    return Ok(());
                }
                let c = payload.downcast::<char>().unwrap();
                let visible = self.visible_line_count();
                let mut scope = RedrawScope::Full;
                match *c {
                    crate::drivers::ps2::KEY_UP => {
                        self.history_prev();
                        if self.scroll_offset == 0 {
                            scope = RedrawScope::InputLine;
                        }
                    }
                    crate::drivers::ps2::KEY_DOWN => {
                        self.history_next();
                        if self.scroll_offset == 0 {
                            scope = RedrawScope::InputLine;
                        }
                    }
                    crate::drivers::ps2::KEY_SHIFT_UP => {
                        self.cancel_history_browse();
                        let before = self.scroll_offset;
                        self.scroll_up(visible);
                        scope = if self.scroll_offset != before {
                            RedrawScope::Full
                        } else {
                            RedrawScope::Skip
                        };
                    }
                    crate::drivers::ps2::KEY_SHIFT_DOWN => {
                        self.cancel_history_browse();
                        let before = self.scroll_offset;
                        self.scroll_down(visible);
                        scope = if self.scroll_offset != before {
                            RedrawScope::Full
                        } else {
                            RedrawScope::Skip
                        };
                    }
                    '\n' => {
                        let line = alloc::string::String::from_iter(self.input_buffer.drain(..));
                        if !line.is_empty() {
                            let (cmd, _) = Self::parse_args(&line);
                            if cmd == "clear" {
                                self.lines.clear();
                                self.scroll_offset = 0;
                                self.push_history(line);
                                scope = RedrawScope::Full;
                            } else {
                                self.push_input_line(line.clone());
                                self.execute_command(&line);
                                self.push_history(line);
                                scope = RedrawScope::Full;
                            }
                        } else {
                            scope = RedrawScope::InputLine;
                        }
                        self.cancel_history_browse();
                        self.scroll_offset = 0;
                    }
                    '\x08' => {
                        self.cancel_history_browse();
                        self.scroll_offset = 0;
                        self.input_buffer.pop();
                        scope = RedrawScope::InputLine;
                    }
                    '\t' => {
                        self.cancel_history_browse();
                        self.scroll_offset = 0;
                        self.input_buffer.push('\t');
                        scope = RedrawScope::InputLine;
                    }
                    _ => {
                        self.cancel_history_browse();
                        self.scroll_offset = 0;
                        self.input_buffer.push(*c);
                        scope = RedrawScope::InputLine;
                    }
                }
                self.clamp_scroll_offset();
                if self.history_index.is_some() {
                    scope = RedrawScope::Full;
                } else if scope == RedrawScope::InputLine && self.scroll_offset > 0 {
                    scope = RedrawScope::Skip;
                }
                if scope == RedrawScope::InputLine || self.history_index.is_some() {
                    self.show_cursor();
                }
                self.redraw(scope);
            }
            _ => return Err(crate::proc::IpcReceiveError::Message("Wrong package type")),
        }
        Ok(())
    }
    fn bind(&mut self, _subscriber: u32) {}
}

#[derive(PartialEq)]
enum RedrawScope {
    Full,
    InputLine,
    CommitLine,
    Skip,
}

impl Shell {
    const TAB_WIDTH: usize = 4;
    const MAX_LINES: usize = 2048;
    const MAX_HISTORY: usize = 256;
    const FONT_SIZE: f32 = 20.0;
    const PROMPT_INPUT: &'static str = "$HLL < ";
    const PROMPT_OUTPUT: &'static str = "$HLL > ";
    const PROMPT_COLOR: u32 = crate::kui::PALETTE_AMBER;
    const INPUT_TEXT_COLOR: u32 = crate::kui::PALETTE_CYAN;
    const OUTPUT_TEXT_COLOR: u32 = crate::kui::PALETTE_LIGHT_CYAN;
    const ERROR_TEXT_COLOR: u32 = crate::kui::PALETTE_ORANGE;
    const MUTED_TEXT_COLOR: u32 = crate::kui::PALETTE_MUTED;
    /// PIT runs at 100 Hz; 25 ticks ≈ 250 ms per cursor phase.
    const CURSOR_BLINK_TICKS: u64 = 25;

    fn visible_line_count(&self) -> usize {
        let Some(content) = self.content else {
            return 1;
        };
        let (_, text_y) = crate::kui::window_text_origin(&content);
        let line_h =
            crate::kui::kdraw::line_height(&crate::kui::kfont::ICELAND, Self::FONT_SIZE) as u32;
        let content_bottom = content.y.saturating_add(content.h);
        let available = content_bottom.saturating_sub(text_y);
        (available / line_h.max(1)).max(1) as usize
    }

    fn clamp_scroll_offset(&mut self) {
        let visible = self.visible_line_count();
        let max = self.max_scroll_offset(visible);
        if self.scroll_offset > max {
            self.scroll_offset = max;
        }
    }

    fn logical_row_count(&self) -> usize {
        self.lines.len() + 1
    }

    fn max_scroll_offset(&self, visible: usize) -> usize {
        self.logical_row_count().saturating_sub(visible)
    }

    fn scroll_up(&mut self, visible: usize) {
        if self.scroll_offset < self.max_scroll_offset(visible) {
            self.scroll_offset += 1;
        }
        self.clamp_scroll_offset();
    }

    fn scroll_down(&mut self, _visible: usize) {
        if self.scroll_offset > 0 {
            self.scroll_offset -= 1;
        }
        self.clamp_scroll_offset();
    }

    fn cancel_history_browse(&mut self) {
        self.history_index = None;
        self.history_draft.clear();
    }

    fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }
        if self.history_index.is_none() {
            self.history_draft = self.input_buffer.clone();
            self.history_index = Some(self.history.len() - 1);
            self.scroll_offset = 0;
        } else if let Some(index) = self.history_index {
            if index == 0 {
                return;
            }
            self.history_index = Some(index - 1);
        }
        if let Some(index) = self.history_index {
            self.load_history_entry(index);
        }
    }

    fn history_next(&mut self) {
        let Some(index) = self.history_index else {
            return;
        };
        if index + 1 < self.history.len() {
            self.history_index = Some(index + 1);
            self.load_history_entry(index + 1);
        } else {
            self.history_index = None;
            self.input_buffer = self.history_draft.clone();
            self.history_draft.clear();
        }
    }

    fn load_history_entry(&mut self, index: usize) {
        let Some(line) = self.history.get(index) else {
            return;
        };
        self.input_buffer = line.chars().collect();
    }

    fn push_shell_line(&mut self, kind: ShellLineKind, line: alloc::string::String) {
        self.lines.push_back(ShellLine { kind, text: line });
        while self.lines.len() > Self::MAX_LINES {
            self.lines.pop_front();
            if self.scroll_offset > 0 {
                self.scroll_offset -= 1;
            }
        }
    }

    fn push_input_line(&mut self, line: alloc::string::String) {
        self.push_shell_line(ShellLineKind::Input, line);
    }

    fn push_history(&mut self, line: alloc::string::String) {
        if self.history.back().is_some_and(|last| last == &line) {
            return;
        }
        self.history.push_back(line);
        while self.history.len() > Self::MAX_HISTORY {
            self.history.pop_front();
            if let Some(index) = self.history_index {
                if index == 0 {
                    self.history_index = None;
                    self.history_draft.clear();
                } else {
                    self.history_index = Some(index - 1);
                }
            }
        }
    }

    fn input_buffer_string(&self) -> alloc::string::String {
        alloc::string::String::from_iter(self.input_buffer.iter().copied())
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

    fn visible_row_range(&self) -> (usize, usize) {
        let visible = self.visible_line_count();
        let total = self.lines.len() + 1;
        let end = total.saturating_sub(self.scroll_offset);
        let start = end.saturating_sub(visible);
        (start, end)
    }

    fn row_kind(&self, row: usize) -> ShellLineKind {
        if row < self.lines.len() {
            self.lines[row].kind
        } else {
            ShellLineKind::Input
        }
    }

    fn row_text(&self, row: usize) -> alloc::string::String {
        if row < self.lines.len() {
            Self::expand_tabs(&self.lines[row].text)
        } else {
            Self::expand_tabs(&self.input_buffer_string())
        }
    }

    fn line_text_color(kind: ShellLineKind, text: &str) -> u32 {
        if kind == ShellLineKind::Input {
            return Self::INPUT_TEXT_COLOR;
        }
        if text.starts_with("error:") || text.starts_with("ipc error:") {
            Self::ERROR_TEXT_COLOR
        } else if text.is_empty() {
            Self::MUTED_TEXT_COLOR
        } else {
            Self::OUTPUT_TEXT_COLOR
        }
    }

    fn is_input_focused(&self) -> bool {
        let Some(handle) = self.window else {
            return false;
        };
        crate::kui::window::WINDOW_MANAGER.lock().is_focused(handle)
    }

    fn show_cursor(&mut self) {
        self.cursor_visible = true;
        self.cursor_blink_last = crate::time::monotonic_ms();
    }

    fn ensure_prompt_width(&mut self) {
        if self.prompt_width == 0 {
            self.prompt_width = crate::kui::kdraw::text_length(
                Self::PROMPT_INPUT,
                &crate::kui::kfont::ICELAND,
                Self::FONT_SIZE,
            ) as u32;
        }
    }

    fn draw_row(
        &self,
        x: u32,
        y: u32,
        kind: ShellLineKind,
        line: &str,
        content: &crate::kui::WindowContentRect,
    ) {
        let font = &crate::kui::kfont::ICELAND;
        let prompt = if kind == ShellLineKind::Input {
            Self::PROMPT_INPUT
        } else {
            Self::PROMPT_OUTPUT
        };
        let Some(handle) = self.window else {
            return;
        };
        let _ = crate::kui::draw_text_in_window(
            handle,
            self.pid,
            x,
            y,
            Self::FONT_SIZE,
            font,
            prompt,
            Self::PROMPT_COLOR,
            content.x,
            content.y,
            content.w,
            content.h,
        );
        let _ = crate::kui::draw_text_in_window(
            handle,
            self.pid,
            x + self.prompt_width,
            y,
            Self::FONT_SIZE,
            font,
            line,
            Self::line_text_color(kind, line),
            content.x,
            content.y,
            content.w,
            content.h,
        );
    }

    fn input_row_slot(&self) -> u32 {
        let (start, end) = self.visible_row_range();
        end.saturating_sub(start).saturating_sub(1) as u32
    }

    fn draw_cursor(&self, text_x: u32, y: u32, line_h: u32, input_text: &str) {
        if !self.cursor_visible {
            return;
        }
        let Some(handle) = self.window else {
            return;
        };
        let cursor_x = text_x
            + self.prompt_width
            + crate::kui::kdraw::text_length(
                input_text,
                &crate::kui::kfont::ICELAND,
                Self::FONT_SIZE,
            ) as u32;
        let cursor_h = line_h.saturating_sub(4).max(4);
        let _ = crate::kui::draw_rect_f_in_window(
            handle,
            self.pid,
            cursor_x,
            y + 2,
            2,
            cursor_h,
            Self::INPUT_TEXT_COLOR,
        );
    }

    fn draw_input_line(
        &self,
        text_x: u32,
        text_y: u32,
        line_h: u32,
        content: &crate::kui::WindowContentRect,
    ) {
        let y = text_y + self.input_row_slot() * line_h;
        let line = self.row_text(self.lines.len());
        let Some(handle) = self.window else {
            return;
        };
        let _ = crate::kui::draw_rect_f_in_window(
            handle, self.pid, content.x, y, content.w, line_h, 0x000000,
        );
        self.draw_row(text_x, y, ShellLineKind::Input, &line, content);
        self.draw_cursor(text_x, y, line_h, &line);
    }

    fn redraw(&mut self, scope: RedrawScope) {
        if scope == RedrawScope::Skip {
            return;
        }

        let Some(content) = self.content else {
            return;
        };
        let Some(handle) = self.window else {
            return;
        };

        self.ensure_prompt_width();

        let (text_x, text_y) = crate::kui::window_text_origin(&content);
        let line_h =
            crate::kui::kdraw::line_height(&crate::kui::kfont::ICELAND, Self::FONT_SIZE) as u32;

        match scope {
            RedrawScope::Skip => {}
            RedrawScope::Full => {
                let _ = crate::kui::draw_rect_f_in_window(
                    handle, self.pid, content.x, content.y, content.w, content.h, 0x000000,
                );
                let (start, end) = self.visible_row_range();
                for (i, row) in (start..end).enumerate() {
                    let kind = self.row_kind(row);
                    let line = self.row_text(row);
                    let y = text_y + i as u32 * line_h;
                    self.draw_row(text_x, y, kind, &line, &content);
                    if row == self.lines.len() {
                        self.draw_cursor(text_x, y, line_h, &line);
                    }
                }
            }
            RedrawScope::InputLine => {
                self.draw_input_line(text_x, text_y, line_h, &content);
            }
            RedrawScope::CommitLine => {
                let (start, _) = self.visible_row_range();
                let committed_row = self.lines.len().saturating_sub(1);
                let row_slot = committed_row.saturating_sub(start) as u32;
                let y = text_y + row_slot * line_h;
                let line = self.row_text(committed_row);
                let _ = crate::kui::draw_rect_f_in_window(
                    handle, self.pid, content.x, y, content.w, line_h, 0x000000,
                );
                self.draw_row(text_x, y, ShellLineKind::Input, &line, &content);
                self.draw_input_line(text_x, text_y, line_h, &content);
            }
        }
    }

    fn parse_args<'a>(line: &'a str) -> (&'a str, alloc::vec::Vec<&'a str>) {
        let mut parts = line.split_whitespace();
        let cmd = parts.next().unwrap_or("");
        (cmd, parts.collect())
    }

    fn parse_u32(s: &str) -> Option<u32> {
        let mut n = 0u32;
        if s.is_empty() {
            return None;
        }
        for c in s.chars() {
            if !c.is_ascii_digit() {
                return None;
            }
            n = n.checked_mul(10)?.checked_add(c.to_digit(10)? as u32)?;
        }
        Some(n)
    }

    fn parse_usize(s: &str) -> Option<usize> {
        let mut n = 0usize;
        if s.is_empty() {
            return None;
        }
        for c in s.chars() {
            if !c.is_ascii_digit() {
                return None;
            }
            n = n.checked_mul(10)?.checked_add(c.to_digit(10)? as usize)?;
        }
        Some(n)
    }

    fn push_output(&mut self, line: alloc::string::String) {
        self.push_shell_line(ShellLineKind::Output, line);
    }

    fn push_blank_output(&mut self) {
        self.push_output(alloc::string::String::new());
    }

    fn format_mib(bytes: usize) -> alloc::string::String {
        alloc::format!("{:>10.3} MiB", bytes as f32 / 1024.0 / 1024.0)
    }

    fn pid_exists(pid: u32) -> bool {
        crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .any(|entry| entry.pid == pid)
    }

    fn process_pid_by_name(name: &str) -> Option<u32> {
        crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .find(|entry| entry.name == name)
            .map(|entry| entry.pid)
    }

    fn queue_pid_command(&mut self, verb: &str, args: &[&str]) {
        let Some(pid) = args.first().and_then(|s| Self::parse_u32(s)) else {
            self.push_output(alloc::format!("error: usage {verb} <pid>"));
            return;
        };
        if !Self::pid_exists(pid) {
            self.push_output(alloc::format!("error: no process with pid {pid}"));
            return;
        }
        match verb {
            "kill" => crate::proc::create_kill_task(pid),
            "freeze" => crate::proc::create_freeze_task(pid),
            "unfreeze" => crate::proc::create_unfreeze_task(pid),
            _ => return,
        }
        self.push_output(alloc::format!("ok: queued {verb} for pid {pid}"));
    }

    fn cmd_mem(&mut self) {
        let alloc = &crate::mem::ALLOCATOR;
        self.push_output(alloc::string::String::from("Memory"));
        self.push_output(alloc::format!(
            "  total     {}",
            Self::format_mib(alloc.total())
        ));
        self.push_output(alloc::format!(
            "  used      {}",
            Self::format_mib(alloc.used())
        ));
        self.push_output(alloc::format!(
            "  free      {}",
            Self::format_mib(alloc.free())
        ));
        self.push_output(alloc::format!(
            "  nodes     {:>10}",
            alloc.free_node_count()
        ));
        self.push_output(alloc::format!("  allocs    {:>10}", alloc.alloc_ops()));
        self.push_output(alloc::format!("  deallocs  {:>10}", alloc.dealloc_ops()));
        self.push_output(alloc::format!("  leaked    {:>10} B", alloc.leaked()));
    }

    fn cmd_alloc(&mut self, args: &[&str]) {
        let Some(kib) = args.first().and_then(|s| Self::parse_usize(s)) else {
            self.push_output(alloc::string::String::from("error: usage alloc <kib>"));
            return;
        };
        let bytes = kib.saturating_mul(1024);
        self.held_allocs.push(alloc::vec![0u8; bytes]);
        self.push_output(alloc::format!(
            "ok: allocated {kib} KiB  (held: {} chunk(s))",
            self.held_allocs.len()
        ));
        self.cmd_mem();
    }

    fn cmd_leak(&mut self, args: &[&str]) {
        let Some(kib) = args.first().and_then(|s| Self::parse_usize(s)) else {
            self.push_output(alloc::string::String::from("error: usage leak <kib>"));
            return;
        };
        let bytes = kib.saturating_mul(1024);
        let leaked = alloc::vec![0u8; bytes].into_boxed_slice();
        let _ = alloc::boxed::Box::leak(leaked);
        self.push_output(alloc::format!("ok: leaked {kib} KiB"));
        self.push_output(alloc::format!(
            "  total leaked  {:>10} B",
            crate::mem::ALLOCATOR.leaked()
        ));
    }

    fn format_ofs_response(msg: &str) -> alloc::vec::Vec<alloc::string::String> {
        let mut lines = alloc::vec::Vec::new();
        if msg.starts_with("error:") {
            lines.push(alloc::string::String::from(msg));
            return lines;
        }
        if msg == "(no files)" {
            lines.push(alloc::string::String::from("  (no files)"));
            return lines;
        }
        if msg.contains('\n') {
            let is_file_list = msg.lines().all(|line| {
                let t = line.trim();
                t.is_empty() || (t.contains(" block") && t.starts_with(' '))
            }) && msg.contains(" block");
            if is_file_list {
                lines.push(alloc::string::String::from("Files"));
            }
            for part in msg.split('\n') {
                let trimmed = part.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if is_file_list && !trimmed.ends_with(':') && !trimmed.starts_with('[') {
                    lines.push(alloc::format!("  {trimmed}"));
                } else {
                    lines.push(alloc::string::String::from(trimmed));
                }
            }
            return lines;
        }
        if msg.ends_with(':') && msg.contains(" block") {
            lines.push(alloc::string::String::from(msg));
            return lines;
        }
        lines.push(alloc::string::String::from(msg));
        lines
    }

    fn push_ofs_response(&mut self, msg: alloc::string::String) {
        for line in Self::format_ofs_response(&msg) {
            self.push_output(line);
        }
    }

    fn cmd_ofs(&mut self, args: &[&str]) {
        let Some(sub) = args.first() else {
            self.push_output(alloc::string::String::from(
                "error: usage ofs start | ofs list | ofs write <name> <data> | ofs read <name> [block]",
            ));
            return;
        };
        match *sub {
            "start" => match crate::proc::spawn::spawn_by_name("ofs", &[]) {
                Ok(()) => {
                    self.push_output(alloc::string::String::from("ok: queued ofs driver spawn"));
                }
                Err(crate::proc::spawn::SpawnError::AlreadyRunning) => {
                    self.push_output(alloc::string::String::from(
                        "ok: ofs driver already running",
                    ));
                }
                Err(crate::proc::spawn::SpawnError::UnknownProcess) => {
                    self.push_output(alloc::string::String::from("error: ofs spawn failed"));
                }
            },
            "list" | "write" | "read" => {
                let Some(ofs_pid) = Self::process_pid_by_name("OFS Driver") else {
                    self.push_output(alloc::string::String::from(
                        "error: ofs driver not running (try: ofs start)",
                    ));
                    return;
                };
                let msg = if *sub == "list" {
                    alloc::string::String::from("list")
                } else if *sub == "write" {
                    let Some(name) = args.get(1) else {
                        self.push_output(alloc::string::String::from(
                            "error: usage ofs write <name.ext> <data>",
                        ));
                        return;
                    };
                    let data = args.get(2..).unwrap_or(&[]).join(" ");
                    alloc::format!("write {name} {data}")
                } else {
                    let Some(name) = args.get(1) else {
                        self.push_output(alloc::string::String::from(
                            "error: usage ofs read <name.ext> [block]",
                        ));
                        return;
                    };
                    match args.get(2) {
                        Some(block) => alloc::format!("read {name} {block}"),
                        None => alloc::format!("read {name}"),
                    }
                };
                crate::proc::create_ipc_task(self.pid, ofs_pid, crate::proc::IpcData::Message(msg));
            }
            _ => self.push_output(alloc::format!("error: unknown ofs subcommand: {sub}")),
        }
    }

    fn cmd_cc(&mut self, args: &[&str]) {
        let Some(source_name) = args.first() else {
            self.push_output(alloc::string::String::from(
                "error: usage cc <file.c>",
            ));
            return;
        };
        if !source_name.ends_with(".c") {
            self.push_output(alloc::string::String::from(
                "error: cc expects a .c source file",
            ));
            return;
        }
        if crate::ofs::vfs::find_file_index(source_name).is_none() {
            self.push_output(alloc::format!("error: file not found: {source_name}"));
            return;
        }
        if crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .any(|entry| entry.name == "Compiler")
        {
            self.push_output(alloc::string::String::from(
                "error: compiler already running",
            ));
            return;
        }

        let spawn_args = alloc::vec![
            alloc::string::String::from(*source_name),
            alloc::format!("{}", self.pid),
        ];
        crate::proc::create_spawn_task::<crate::apps::compiler::Compiler>(spawn_args);
        self.push_output(alloc::format!(
            "cc: spawned compiler for {source_name}..."
        ));
    }

    fn cmd_run(&mut self, args: &[&str]) {
        let Some(name) = args.first() else {
            self.push_output(alloc::string::String::from(
                "error: usage run <file.bin>",
            ));
            return;
        };
        if !crate::ofs::vfs::is_executable(name) {
            self.push_output(alloc::format!("error: {name} is not executable"));
            return;
        }
        let bytes = match crate::ofs::vfs::read_all_bytes(name) {
            Ok(bytes) => bytes,
            Err(err) => {
                self.push_output(err);
                return;
            }
        };
        let image = match crate::runtime::parse_bin(&bytes) {
            Ok(image) => image,
            Err(err) => {
                self.push_output(err);
                return;
            }
        };
        crate::runtime::queue_run(
            image,
            alloc::vec![alloc::string::String::from(*name)],
            self.pid,
        );
    }

    fn cmd_keymap(&mut self, args: &[&str]) {
        let Some(name) = args.first() else {
            let current = match crate::drivers::ps2::keymap() {
                crate::drivers::ps2::Keymap::Us => "us",
                crate::drivers::ps2::Keymap::De => "de",
            };
            self.push_output(alloc::format!("keymap: {current}"));
            self.push_output(alloc::string::String::from("usage: keymap us | keymap de"));
            return;
        };
        match *name {
            "us" | "en" | "qwerty" => {
                crate::drivers::ps2::set_keymap(crate::drivers::ps2::Keymap::Us);
                self.push_output(alloc::string::String::from("ok: keymap us"));
            }
            "de" | "qwertz" => {
                crate::drivers::ps2::set_keymap(crate::drivers::ps2::Keymap::De);
                self.push_output(alloc::string::String::from("ok: keymap de"));
            }
            _ => self.push_output(alloc::format!("error: unknown keymap: {name}")),
        }
    }

    fn cmd_spawn(&mut self, args: &[&str]) {
        let Some(name) = args.first() else {
            self.push_output(alloc::string::String::from("Spawnable processes"));
            for entry in crate::proc::spawn::list_spawnable() {
                self.push_output(alloc::format!(
                    "  {}  ({})",
                    entry.aliases.join(", "),
                    entry.running_name
                ));
            }
            self.push_output(alloc::string::String::from(
                "usage: spawn <name> [args...]",
            ));
            return;
        };
        let spawn_args = args.get(1..).unwrap_or(&[]);
        match crate::proc::spawn::spawn_by_name(name, spawn_args) {
            Ok(()) => self.push_output(alloc::format!("ok: queued spawn {name}")),
            Err(crate::proc::spawn::SpawnError::AlreadyRunning) => {
                let running = crate::proc::spawn::list_spawnable()
                    .iter()
                    .find(|entry| entry.aliases.contains(name))
                    .map(|entry| entry.running_name)
                    .unwrap_or(name);
                self.push_output(alloc::format!("error: {running} already running"));
            }
            Err(crate::proc::spawn::SpawnError::UnknownProcess) => {
                self.push_output(alloc::format!("error: unknown process: {name}"));
            }
        }
    }

    fn cmd_help(&mut self) {
        self.push_output(alloc::string::String::from("OwOS Shell Commands"));
        self.push_output(alloc::string::String::from(
            "  help              this message",
        ));
        self.push_output(alloc::string::String::from(
            "  version           show OwOS version",
        ));
        self.push_output(alloc::string::String::from(
            "  echo <text...>    print text",
        ));
        self.push_output(alloc::string::String::from(
            "  clear             clear scrollback",
        ));
        self.push_output(alloc::string::String::from(
            "  ps                list processes",
        ));
        self.push_output(alloc::string::String::from(
            "  spawn [name] ...  list or launch a process",
        ));
        self.push_output(alloc::string::String::from(
            "  kill <pid>        kill process",
        ));
        self.push_output(alloc::string::String::from(
            "  freeze <pid>      freeze process",
        ));
        self.push_output(alloc::string::String::from(
            "  unfreeze <pid>    unfreeze process",
        ));
        self.push_output(alloc::string::String::from(
            "  mem               memory stats",
        ));
        self.push_output(alloc::string::String::from(
            "  alloc <kib>       allocate and hold",
        ));
        self.push_output(alloc::string::String::from(
            "  leak <kib>        permanently leak",
        ));
        self.push_output(alloc::string::String::from(
            "  panic             trigger kernel panic",
        ));
        self.push_output(alloc::string::String::from(
            "  breakpoint        trigger int3 breakpoint fault",
        ));
        self.push_output(alloc::string::String::from(
            "  ofs start         spawn OFS driver",
        ));
        self.push_output(alloc::string::String::from(
            "  ofs list          list files",
        ));
        self.push_output(alloc::string::String::from(
            "  ofs write ...     write file block",
        ));
        self.push_output(alloc::string::String::from(
            "  ofs read ...      read file (all or one block)",
        ));
        self.push_output(alloc::string::String::from(
            "  keymap us|de      switch keyboard layout",
        ));
        self.push_output(alloc::string::String::from(
            "  cc <file.c>       compile C source via TCC to .bin",
        ));
        self.push_output(alloc::string::String::from(
            "  run <file.bin>    execute compiled program",
        ));
        self.push_output(alloc::string::String::from(
            "  edit [file]       open graphical text editor",
        ));
        self.push_blank_output();
    }

    fn cmd_edit(&mut self, args: &[&str]) {
        if crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .any(|entry| entry.name == "Text Editor")
        {
            self.push_output(alloc::string::String::from(
                "error: text editor already running",
            ));
            return;
        }
        let spawn_args: alloc::vec::Vec<alloc::string::String> = args
            .iter()
            .map(|arg| alloc::string::String::from(*arg))
            .collect();
        crate::proc::create_spawn_task::<crate::apps::texteditor::TextEditor>(spawn_args);
        if let Some(file) = args.first() {
            self.push_output(alloc::format!("ok: opened editor for {file}"));
        } else {
            self.push_output(alloc::string::String::from("ok: opened editor"));
        }
    }

    fn execute_command(&mut self, line: &str) {
        let (cmd, args) = Self::parse_args(line);
        match cmd {
            "help" => self.cmd_help(),
            "version" => {
                self.push_output(alloc::format!(
                    "{} v{}",
                    env!("CARGO_PKG_NAME"),
                    env!("CARGO_PKG_VERSION")
                ));
            }
            "echo" => {
                if args.is_empty() {
                    self.push_output(alloc::string::String::new());
                } else {
                    self.push_output(args.join(" "));
                }
            }
            "clear" => {}
            "ps" => {
                let table = crate::proc::registry::PROCESS_TABLE.lock();
                if table.is_empty() {
                    self.push_output(alloc::string::String::from("  (no processes)"));
                } else {
                    self.push_output(alloc::format!(
                        "  {:>3}  {:<16}  {}",
                        "PID",
                        "NAME",
                        "STATUS"
                    ));
                    for entry in table.iter() {
                        self.push_output(alloc::format!(
                            "  {:>3}  {:<16}  {:?}",
                            entry.pid,
                            entry.name,
                            entry.status
                        ));
                    }
                }
            }
            "kill" | "freeze" | "unfreeze" => self.queue_pid_command(cmd, &args),
            "mem" => self.cmd_mem(),
            "alloc" => self.cmd_alloc(&args),
            "leak" => self.cmd_leak(&args),
            "panic" => panic!("shell: panic command"),
            "breakpoint" => {
                unsafe {
                    core::arch::asm!("int3", options(nomem, nostack));
                }
            }
            "ofs" => self.cmd_ofs(&args),
            "keymap" => self.cmd_keymap(&args),
            "cc" => self.cmd_cc(&args),
            "run" => self.cmd_run(&args),
            "spawn" => self.cmd_spawn(&args),
            "edit" => self.cmd_edit(&args),
            "" => {}
            _ => self.push_output(alloc::format!("error: unknown command: {cmd}")),
        }
    }
}
