pub struct OfsDriver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    files: alloc::vec::Vec<crate::ofs::PlaintextFile>,
}

impl crate::proc::Process for OfsDriver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "OFS File System Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            files: alloc::vec::Vec::new()
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

    fn on_init(&self) {
        
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(mut self: alloc::boxed::Box<Self>) {
        self.files.clear();
    }
}