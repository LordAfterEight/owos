pub struct MemTracker {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,
    tick_count: u32,
    report_every: u32,
}

impl crate::proc::Process for MemTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "Memory Tracker",
            status: crate::proc::ProcessStatus::Running,
            tick_count: 0,
            report_every: 100_000,
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
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        self.tick_count += 1;
        if self.tick_count.is_multiple_of(self.report_every) {
            let total = crate::mem::ALLOCATOR.total();
            let used  = crate::mem::ALLOCATOR.used();
            let free  = crate::mem::ALLOCATOR.free();

            let text = alloc::format!(
                "Total: {:.3} MiB | Used: {:.3} MiB | Free: {:.3} MiB | Free nodes: {}",
                total as f32 / 1024.0 / 1024.0,
                used  as f32 / 1024.0 / 1024.0,
                free  as f32 / 1024.0 / 1024.0,
                crate::mem::ALLOCATOR.free_node_count()
            );

            let text_width = crate::kui::kdraw::text_length(&text, &crate::kui::kfont::KODEMONO_REGULAR, 15.0) as u32;
            let x_pos = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0.width as u32
                - 10
                - text_width;
            
            crate::kui::draw_rect(
                x_pos - 25,
                10,
                text_width + 25,
                18,
                15,
                0
            );
            crate::kui::draw_text(
                x_pos,
                10, 
                15.0,
                &crate::kui::kfont::KODEMONO_REGULAR,
                &text,
                0x55EAD4
            );
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    
    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }
}
