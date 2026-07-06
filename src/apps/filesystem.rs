use alloc::string::ToString;

#[derive(Debug)]
pub struct OfsDriver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    files: alloc::vec::Vec<crate::ofs::PlaintextFile>,
    ticks: u32,
    closing: bool,
}

impl OfsDriver {
    fn closing_procedure(&mut self) -> Option<crate::proc::ProcessEvent> {
        if self.closing {
            for _ in 0..1000 {
                if self.files.pop().is_none() {
                    break;
                }
            }
            if self.files.is_empty() {
                return Some(crate::proc::ProcessEvent::Closed(0));
            }

            return Some(crate::proc::ProcessEvent::Yielded);
        }
        None
    }
}

impl crate::proc::Process for OfsDriver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "OFS Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            files: alloc::vec::Vec::new(),
            ticks: 0,
            closing: false,
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

    fn on_init(&self) {}

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if let Some(event) = self.closing_procedure() {
            return Ok(event);
        }
        let pid = 0;
        self.ticks += 1;

        if self.ticks.is_multiple_of(10_000_000) {
            crate::klog::log(
                self.name,
                &alloc::format!("Sending IPC data (Message) to PID {}", pid),
                crate::klog::MessageType::Info,
            );
            crate::proc::create_ipc_task(
                self.pid,
                pid,
                crate::proc::IpcData::Message("Testing Payload".to_string()),
            );
            crate::klog::log(
                self.name,
                &alloc::format!("Sending IPC data (Payload) to PID {}", pid),
                crate::klog::MessageType::Info,
            );
            crate::proc::create_ipc_task(
                self.pid,
                pid,
                crate::proc::IpcData::Payload(OfsDriver::new()),
            );
        }

        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(mut self: alloc::boxed::Box<Self>) {
        self.files.clear();
    }

    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        let msg_type = match data {
            crate::proc::IpcData::SendError(_) => crate::klog::MessageType::Error,
            _ => crate::klog::MessageType::Info
        };
        crate::klog::log(
            self.name,
            &alloc::format!("Received IPC data: {:?}", data),
            msg_type
        );
        Ok(())
    }
}
