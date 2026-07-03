pub struct ProcessTracker {
    pid: u32,
    name: &'static str,
    status: crate::proc::ProcessStatus,
    tick_count: u32,
    report_every: u32,
    current_amount: u32,
    last_amount: u32,
}

impl crate::proc::Process for ProcessTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "ProcessTracker",
            status: crate::proc::ProcessStatus::Running,
            tick_count: 0,
            report_every: 1_000_000,
            current_amount: 0,
            last_amount: 0,
        })
    }

    fn on_init(&self) {
        crate::println!("[{}] init (pid {})", self.name, self.pid);
        crate::kui::ktitledwindow("Process Tracker");
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        self.tick_count += 1;
        if self.tick_count % self.report_every == 0 {
            let table = crate::proc::registry::PROCESS_TABLE.lock();
            //crate::println!("--- {} processes alive ---", table.len());
            for (i, entry) in table.iter().enumerate() {
                if i < self.last_amount as usize {
                    crate::kui::ktitledwindow("Process Tracker");
                }
                self.last_amount = i as u32;
                // crate::println!(
                //     "  pid {:>3}  {:<16} {:?}",
                //     entry.pid,
                //     entry.name,
                //     entry.status
                // );
                let text =
                    &alloc::format!("PID: {} | {} | {:?}", entry.pid, entry.name, entry.status);
                crate::kui::draw_rect(
                    20,
                    65 + i as u32 * 20,
                    crate::kui::kdraw::text_length(text, &crate::kui::kfont::KODEMONO_BOLD, 15.0) as u32,
                    18,
                    15,
                    0
                );
                crate::kui::draw_text(
                    20,
                    65 + i as u32 * 20,
                    15.0,
                    &crate::kui::kfont::KODEMONO_BOLD,
                    text,
                    0x55EAD4,
                );
            }
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {
        crate::println!("[{}] uninit", self.name);
    }

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
}