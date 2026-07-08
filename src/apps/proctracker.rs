pub struct ProcessTracker {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,

    tick_count: u32,
    report_every: u32,
    current_amount: u32,
    last_amount: u32,

    draw_to_screen: bool
}

impl crate::proc::Process for ProcessTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "ProcessTracker",
            status: crate::proc::ProcessStatus::Running,

            tick_count: 0,
            report_every: 10_000_000,
            current_amount: 0,
            last_amount: 0,

            draw_to_screen: true,
        })
    }

    fn on_init(&self) {
        if self.draw_to_screen {
            crate::kui::ktitledwindow("Process Tracker");
        }
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        self.tick_count += 1;
        if self.tick_count.is_multiple_of(self.report_every) {
            if self.current_amount < self.last_amount {
                crate::klog::log(
                    self.name,
                    &alloc::format!(
                        "One or more processes closed. {} active",
                        self.current_amount
                    ),
                    crate::klog::MessageType::Info
                );
                crate::kui::ktitledwindow("Process Tracker");
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
            if !self.draw_to_screen { crate::println!("--- {} processes alive ---", table.len()) };
            for (i, entry) in table.iter().enumerate() {
                if self.draw_to_screen {
                    let text =
                        &alloc::format!("PID: {} | {} | {:?}", entry.pid, entry.name, entry.status);
                    crate::kui::draw_rect(
                        20,
                        65 + i as u32 * 20,
                        crate::kui::kdraw::text_length(text, &crate::kui::kfont::KODEMONO_BOLD, 15.0)
                            as u32,
                        18,
                        15,
                        0,
                    );
                    crate::kui::draw_text(
                        20,
                        65 + i as u32 * 20,
                        15.0,
                        &crate::kui::kfont::KODEMONO_BOLD,
                        text,
                        0x55EAD4,
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

    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Err(crate::proc::IpcReceiveError::Message("Not expecting any data"))
    }
    fn bind(&mut self, _subscriber: u32) {}
}