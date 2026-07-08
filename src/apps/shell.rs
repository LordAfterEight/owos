pub struct Shell {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    ticks: u64,
    input_buffer: alloc::vec::Vec<char>,
}

impl crate::proc::Process for Shell {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Shell",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            ticks: 0,
            input_buffer: alloc::vec::Vec::new(),
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
        crate::proc::create_binding_task(self.pid, 1);
    }
    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if self.ticks.is_multiple_of(50_000) {
            crate::kui::kdraw::draw_text(
                20,
                60,
                20.0,
                &crate::kui::kfont::ICELAND,
                &alloc::string::String::from_iter(self.input_buffer.iter()),
                0x55EAD4,
            );
        }
        self.ticks += 1;
        Ok(crate::proc::ProcessEvent::Yielded)
    }
    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        match data {
            crate::proc::IpcData::Payload(payload) => {
                let c = payload.downcast::<char>().unwrap();
                self.input_buffer.push(*c);
                crate::klog::log(
                    self.name,
                    &alloc::format!("Received character: {}", c),
                    crate::klog::MessageType::Info,
                );
            }
            _ => return Err(crate::proc::IpcReceiveError::Message("Wrong package type")),
        }
        Ok(())
    }
    fn bind(&mut self, _subscriber: u32) {}
}
