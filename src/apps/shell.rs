use alloc::boxed::Box;
use alloc::format;
use alloc::vec::Vec;

use crate::proc::{
    IpcData, IpcReceiveError, ProcessEvent, ProcessError, ProcessStatus,
};

pub struct Shell {
    name: &'static str,
    pid: u32,
    status: ProcessStatus,

    ticks: u64,
    input_buffer: Vec<char>,
}

impl crate::proc::Process for Shell {
    fn new() -> Box<Self> {
        Box::new(Self {
            name: "Shell",
            pid: 0,
            status: ProcessStatus::Running,

            ticks: 0,
            input_buffer: Vec::new(),
        })
    }
    fn name(&self) -> &'static str {
        self.name
    }
    fn pid(&self) -> u32 {
        self.pid
    }
    fn status(&self) -> ProcessStatus {
        self.status
    }
    fn set_name(&mut self, name: &'static str) {
        self.name = name
    }
    fn set_pid(&mut self, pid: u32) {
        self.pid = pid
    }
    fn set_status(&mut self, status: ProcessStatus) {
        self.status = status
    }
    fn on_init(&self) {
        crate::kui::ktitledwindow("Shell");
        crate::proc::create_binding_task(self.pid, 1);
    }
    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
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
        Ok(ProcessEvent::Yielded)
    }
    fn on_uninit(self: Box<Self>) {}
    fn receive(&mut self, data: IpcData) -> Result<(), IpcReceiveError> {
        match data {
            IpcData::Payload(payload) => {
                let c = payload.downcast::<char>().unwrap();
                self.input_buffer.push(*c);
                crate::klog::log(
                    self.name,
                    &format!("Received character: {}", c),
                    crate::klog::MessageType::Info,
                );
            }
            _ => return Err(IpcReceiveError::Message("Wrong package type")),
        }
        Ok(())
    }
    fn bind(&mut self, _subscriber: u32) {}
}