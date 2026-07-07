pub struct MemTracker {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,
    elapsed_ms: u32,
    report_interval_ms: u32,
    needs_window: bool,
    window: Option<crate::kui::WindowHandle>,
    content: Option<crate::kui::WindowContentRect>,
}

impl crate::proc::Process for MemTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "Memory Tracker",
            status: crate::proc::ProcessStatus::Running,
            elapsed_ms: 0,
            report_interval_ms: 1000,
            needs_window: true,
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
        self.name = name
    }
    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }
    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status
    }

    fn on_init(&self) {
        let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
        let sample = alloc::string::String::from(
            "Total: 9999.999 MiB | Used: 9999.999 MiB | Free: 9999.999 MiB | Free nodes: 99999",
        );
        let content_w = crate::kui::kdraw::text_length(
            &sample,
            &crate::kui::kfont::KODEMONO_REGULAR,
            15.0,
        ) as u32
            + 16;
        let content_h = 20u32;
        let (frame_w, frame_h) =
            crate::kui::window::WindowManager::frame_size_for_content(content_w, content_h);
        let frame_x = fb.width as u32 - 10 - frame_w;
        crate::kui::compositor_ipc::request(
            self.pid,
            crate::kui::compositor_ipc::CompositorRequest::CreateWindow {
                owner_pid: self.pid,
                title: alloc::string::String::from("Memory"),
                x: frame_x,
                y: 10,
                w: frame_w,
                h: frame_h,
            },
        );
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if self.needs_window {
            return Ok(crate::proc::ProcessEvent::Yielded);
        }
        self.elapsed_ms = self
            .elapsed_ms
            .saturating_add(crate::time::delta_ms());
        if self.elapsed_ms >= self.report_interval_ms {
            self.elapsed_ms = 0;
            let Some(handle) = self.window else {
                return Ok(crate::proc::ProcessEvent::Yielded);
            };
            let Some(content) = self.content else {
                return Ok(crate::proc::ProcessEvent::Yielded);
            };

            let total = crate::mem::ALLOCATOR.total();
            let used = crate::mem::ALLOCATOR.used();
            let free = crate::mem::ALLOCATOR.free();

            let text = alloc::format!(
                "Total: {:.3} MiB | Used: {:.3} MiB | Free: {:.3} MiB | Free nodes: {}",
                total as f32 / 1024.0 / 1024.0,
                used as f32 / 1024.0 / 1024.0,
                free as f32 / 1024.0 / 1024.0,
                crate::mem::ALLOCATOR.free_node_count()
            );

            let _ = crate::kui::draw_rect_f_in_window(
                handle,
                self.pid,
                0,
                0,
                content.w,
                content.h,
                0,
            );
            let _ = crate::kui::draw_text_in_window(
                handle,
                self.pid,
                4,
                2,
                15.0,
                &crate::kui::kfont::KODEMONO_REGULAR,
                &text,
                crate::kui::PALETTE_CYAN,
                content.x,
                content.y,
                content.w,
                content.h,
            );
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
                }
                Ok(())
            }
            _ => Err(crate::proc::IpcReceiveError::Message("Not expecting any data")),
        }
    }
    fn bind(&mut self, _subscriber: u32) {}
}