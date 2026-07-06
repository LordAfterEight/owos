pub struct Shell {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
}

impl crate::proc::Process for Shell {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Shell",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
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
        Ok(crate::proc::ProcessEvent::Yielded)
    }
    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        match data {
            crate::proc::IpcData::Payload(payload) => {
                crate::klog::log(
                    self.name,
                    &alloc::format!("Received character: {:?}", payload.downcast::<char>().unwrap()),
                    crate::klog::MessageType::Info
                );
            },
            _ => return Err(crate::proc::IpcReceiveError::Message("Wrong package type"))
        }
        Ok(())
    }
    fn bind(&mut self, subscriber: u32) {}
}