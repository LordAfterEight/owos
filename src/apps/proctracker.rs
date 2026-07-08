use alloc::boxed::Box;
use alloc::format;

use crate::kui::kdraw::text_length;
use crate::kui::kfont::KODEMONO_BOLD;
use crate::kui::{draw_rect, draw_text, ktitledwindow};
use crate::proc::{
    IpcData, IpcReceiveError, ProcessEvent, ProcessError, ProcessStatus,
};

pub struct ProcessTracker {
    pid: u32,
    name: &'static str,
    status: ProcessStatus,

    tick_count: u32,
    report_every: u32,
    current_amount: u32,
    last_amount: u32,

    draw_to_screen: bool,
}

impl crate::proc::Process for ProcessTracker {
    fn new() -> Box<Self> {
        Box::new(Self {
            pid: 0,
            name: "ProcessTracker",
            status: ProcessStatus::Running,

            tick_count: 0,
            report_every: 10_000_000,
            current_amount: 0,
            last_amount: 0,

            draw_to_screen: true,
        })
    }

    fn on_init(&self) {
        if self.draw_to_screen {
            ktitledwindow("Process Tracker");
        }
    }

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
        self.tick_count += 1;
        if self.tick_count.is_multiple_of(self.report_every) {
            if self.current_amount < self.last_amount {
                crate::klog::log(
                    self.name,
                    &format!(
                        "One or more processes closed. {} active",
                        self.current_amount
                    ),
                    crate::klog::MessageType::Info,
                );
                ktitledwindow("Process Tracker");
            }
            if self.current_amount > self.last_amount {
                crate::klog::log(
                    self.name,
                    &format!(
                        "Registered {} new process(es)",
                        self.current_amount
                    ),
                    crate::klog::MessageType::Info,
                );
            }
            let table = crate::proc::registry::PROCESS_TABLE.lock();
            if !self.draw_to_screen {
                crate::println!("--- {} processes alive ---", table.len());
            }
            for (i, entry) in table.iter().enumerate() {
                if self.draw_to_screen {
                    let text = &format!("PID: {} | {} | {:?}", entry.pid, entry.name, entry.status);
                    draw_rect(
                        20,
                        65 + i as u32 * 20,
                        text_length(text, &KODEMONO_BOLD, 15.0) as u32,
                        18,
                        15,
                        0,
                    );
                    draw_text(
                        20,
                        65 + i as u32 * 20,
                        15.0,
                        &KODEMONO_BOLD,
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
        Ok(ProcessEvent::Yielded)
    }

    fn on_uninit(self: Box<Self>) {}

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
    fn status(&self) -> ProcessStatus {
        self.status
    }
    fn set_status(&mut self, status: ProcessStatus) {
        self.status = status;
    }

    fn receive(&mut self, _data: IpcData) -> Result<(), IpcReceiveError> {
        Err(IpcReceiveError::Message("Not expecting any data"))
    }
    fn bind(&mut self, _subscriber: u32) {}
}