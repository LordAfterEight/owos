pub struct ProcessTracker {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,

    elapsed_ms: u32,
    report_interval_ms: u32,
    current_amount: u32,
    last_amount: u32,

    draw_to_screen: bool,
    needs_window: bool,
    window: Option<crate::kui::WindowHandle>,
    content: Option<crate::kui::WindowContentRect>,
}

impl crate::proc::Process for ProcessTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "ProcessTracker",
            status: crate::proc::ProcessStatus::Running,

            elapsed_ms: 0,
            report_interval_ms: 5000,
            current_amount: 0,
            last_amount: 0,

            draw_to_screen: true,
            needs_window: true,
            window: None,
            content: None,
        })
    }

    fn on_init(&self) {
        if !self.draw_to_screen {
            return;
        }
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let frame = crate::kui::default_shell_frame(fb);
        crate::kui::compositor_ipc::request(
            self.pid,
            crate::kui::compositor_ipc::CompositorRequest::CreateWindow {
                owner_pid: self.pid,
                title: alloc::string::String::from("Process Tracker"),
                x: frame.x + 40,
                y: frame.y + 40,
                w: frame.w.saturating_sub(80),
                h: frame.h.saturating_sub(80),
            },
        );
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if self.draw_to_screen && self.needs_window {
            return Ok(crate::proc::ProcessEvent::Yielded);
        }
        self.elapsed_ms = self
            .elapsed_ms
            .saturating_add(crate::time::delta_ms());
        if self.elapsed_ms >= self.report_interval_ms {
            self.elapsed_ms = 0;
            if self.current_amount < self.last_amount {
                crate::klog::log(
                    self.name,
                    &alloc::format!(
                        "One or more processes closed. {} active",
                        self.current_amount
                    ),
                    crate::klog::MessageType::Info
                );
            }
            if self.current_amount > self.last_amount {
                crate::klog::log(
                    self.name,
                    &alloc::format!(
                        "Registered {} new process(es)",
                        self.current_amount
                    ),
                    crate::klog::MessageType::Info
                );
            }
            let table = crate::proc::registry::PROCESS_TABLE.lock();
            if !self.draw_to_screen {
                crate::println!("--- {} processes alive ---", table.len());
            };
            if self.draw_to_screen {
                if let (Some(handle), Some(content)) = (self.window, self.content) {
                    let _ = crate::kui::draw_rect_f_in_window(
                        handle,
                        self.pid,
                        0,
                        0,
                        content.w,
                        content.h,
                        0x000000,
                    );
                }
            }
            for (i, entry) in table.iter().enumerate() {
                if self.draw_to_screen {
                    let Some(handle) = self.window else {
                        continue;
                    };
                    let Some(content) = self.content else {
                        continue;
                    };
                    let text =
                        &alloc::format!("PID: {} | {} | {:?}", entry.pid, entry.name, entry.status);
                    let y = 4 + i as u32 * 20;
                    let _ = crate::kui::draw_rect_in_window(
                        handle,
                        self.pid,
                        4,
                        y,
                        crate::kui::kdraw::text_length(text, &crate::kui::kfont::KODEMONO_BOLD, 15.0)
                            as u32
                            + 8,
                        18,
                        15,
                        0,
                    );
                    let _ = crate::kui::draw_text_in_window(
                        handle,
                        self.pid,
                        8,
                        y,
                        15.0,
                        &crate::kui::kfont::KODEMONO_BOLD,
                        text,
                        crate::kui::PALETTE_CYAN,
                        content.x,
                        content.y,
                        content.w,
                        content.h,
                    );
                } else {
                    crate::println!(
                        "  pid {:>3}  {:<16} {:?}",
                        entry.pid,
                        entry.name,
                        entry.status
                    );
                }
                self.current_amount = i as u32 + 1;
            }
            self.last_amount = self.current_amount;
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {}

    fn pid(&self) -> u32 {
        self.pid
    }
    fn name(&self) -> &'static str {
        self.name
    }
    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }
    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }
    fn status(&self) -> crate::proc::ProcessStatus {
        self.status
    }
    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status;
    }

    fn apply_spawn_args(&mut self, args: &[alloc::string::String]) {
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--headless" => self.draw_to_screen = false,
                "--interval" => {
                    if let Some(ms) = args.get(i + 1).and_then(|s| s.parse::<u32>().ok()) {
                        self.report_interval_ms = ms;
                        i += 1;
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }

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
                }
                Ok(())
            }
            _ => Err(crate::proc::IpcReceiveError::Message("Not expecting any data")),
        }
    }
    fn bind(&mut self, _subscriber: u32) {}
}