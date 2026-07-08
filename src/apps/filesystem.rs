use alloc::boxed::Box;
use alloc::vec::Vec;

use crate::proc::{
    IpcData, IpcReceiveError, ProcessEvent, ProcessError, ProcessStatus,
};

#[derive(Debug)]
pub struct OfsDriver {
    name: &'static str,
    pid: u32,
    status: ProcessStatus,

    files: Vec<crate::ofs::PlaintextFile>,
    ticks: u32,
    closing: bool,
}

impl OfsDriver {
    fn closing_procedure(&mut self) -> Option<ProcessEvent> {
        if self.closing {
            for _ in 0..1000 {
                if self.files.pop().is_none() {
                    break;
                }
            }
            if self.files.is_empty() {
                return Some(ProcessEvent::Closed(0));
            }

            return Some(ProcessEvent::Yielded);
        }
        None
    }
}

impl crate::proc::Process for OfsDriver {
    fn new() -> Box<Self> {
        Box::new(Self {
            name: "OFS Driver",
            pid: 0,
            status: ProcessStatus::Running,

            files: Vec::new(),
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

    fn status(&self) -> ProcessStatus {
        self.status
    }

    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }

    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }

    fn set_status(&mut self, status: ProcessStatus) {
        self.status = status;
    }

    fn on_init(&self) {}

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
        if let Some(event) = self.closing_procedure() {
            return Ok(event);
        }
        self.ticks += 1;

        Ok(ProcessEvent::Yielded)
    }

    fn on_uninit(mut self: Box<Self>) {
        self.files.clear();
    }

    fn receive(&mut self, _data: IpcData) -> Result<(), IpcReceiveError> {
        Err(IpcReceiveError::Message("Not expecting any data"))
    }
    fn bind(&mut self, _subscriber: u32) {}
}