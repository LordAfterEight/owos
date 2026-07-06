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

    ticks: u64,
    input_buffer: alloc::vec::Vec<char>,
    lines: alloc::collections::VecDeque<ShellLine>,
    history: alloc::collections::VecDeque<alloc::string::String>,
    scroll_offset: usize,
    history_index: Option<usize>,
    history_draft: alloc::vec::Vec<char>,
    prompt_width: u32,
    needs_initial_draw: bool,
    held_allocs: alloc::vec::Vec<alloc::vec::Vec<u8>>,
}

impl crate::proc::Process for Shell {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Shell",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            ticks: 0,
            input_buffer: alloc::vec::Vec::new(),
            lines: alloc::collections::VecDeque::new(),
            history: alloc::collections::VecDeque::new(),
            scroll_offset: 0,
            history_index: None,
            history_draft: alloc::vec::Vec::new(),
            prompt_width: 0,
            needs_initial_draw: true,
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
        crate::kui::ktitledwindow("Shell");
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
        if self.needs_initial_draw {
            self.needs_initial_draw = false;
            self.redraw(RedrawScope::Full);
        }
        self.ticks += 1;
        Ok(crate::proc::ProcessEvent::Yielded)
    }
    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        match data {
            crate::proc::IpcData::SendConfirmation(msg) => {
                self.push_ofs_response(msg);
                self.redraw(RedrawScope::Full);
            }
            crate::proc::IpcData::SendError(err) => {
                self.push_output(alloc::format!("ipc error: {err}"));
                self.redraw(RedrawScope::Full);
            }
            crate::proc::IpcData::Payload(payload) => {
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
    const PROMPT_COLOR: u32 = 0xF3C200;
    const INPUT_TEXT_COLOR: u32 = 0x55EAD4;
    const OUTPUT_TEXT_COLOR: u32 = 0x9BE8FF;
    const ERROR_TEXT_COLOR: u32 = 0xF38020;
    const MUTED_TEXT_COLOR: u32 = 0x5A9EAA;

    fn visible_line_count(&self) -> usize {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let content = crate::kui::window_content_rect(fb);
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
        crate::kui::draw_text(
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
        crate::kui::draw_text(
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

    fn draw_input_line(
        &self,
        text_x: u32,
        text_y: u32,
        line_h: u32,
        content: &crate::kui::WindowContentRect,
    ) {
        let y = text_y + self.input_row_slot() * line_h;
        let line = self.row_text(self.lines.len());
        crate::kui::draw_rect_f(content.x, y, content.w, line_h, 0x000000);
        self.draw_row(text_x, y, ShellLineKind::Input, &line, content);
    }

    fn redraw(&mut self, scope: RedrawScope) {
        if scope == RedrawScope::Skip {
            return;
        }

        self.ensure_prompt_width();

        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let content = crate::kui::window_content_rect(fb);
        let (text_x, text_y) = crate::kui::window_text_origin(&content);
        let line_h =
            crate::kui::kdraw::line_height(&crate::kui::kfont::ICELAND, Self::FONT_SIZE) as u32;

        match scope {
            RedrawScope::Skip => {}
            RedrawScope::Full => {
                crate::kui::draw_rect_f(content.x, content.y, content.w, content.h, 0x000000);
                let (start, end) = self.visible_row_range();
                for (i, row) in (start..end).enumerate() {
                    let kind = self.row_kind(row);
                    let line = self.row_text(row);
                    let y = text_y + i as u32 * line_h;
                    self.draw_row(text_x, y, kind, &line, &content);
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
                crate::kui::draw_rect_f(content.x, y, content.w, line_h, 0x000000);
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
            "start" => {
                if Self::process_pid_by_name("OFS Driver").is_some() {
                    self.push_output(alloc::string::String::from(
                        "ok: ofs driver already running",
                    ));
                    return;
                }
                crate::proc::create_spawn_task::<crate::apps::filesystem::OfsDriver>();
                self.push_output(alloc::string::String::from("ok: queued ofs driver spawn"));
            }
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
        self.push_blank_output();
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
            "ofs" => self.cmd_ofs(&args),
            "" => {}
            _ => self.push_output(alloc::format!("error: unknown command: {cmd}")),
        }
    }
}
