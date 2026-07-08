use alloc::boxed::Box;
use alloc::format;
use alloc::vec::Vec;
use x86_64::instructions::port::Port;

use crate::proc::{create_ipc_task, IpcData, ProcessEvent, ProcessStatus};
use crate::res::keymaps::{
    QWERTY_ALT, QWERTY_NORMAL, QWERTY_SHIFT, QWERTZ_ALT, QWERTZ_NORMAL, QWERTZ_SHIFT,
};

pub const DATA_PORT: Port<u8> = Port::new(0x60);
pub const STAT_PORT: Port<u8> = Port::new(0x64);

pub struct Ps2Driver {
    name: &'static str,
    pid: u32,
    status: ProcessStatus,

    subscribers: Vec<u32>,
    ticks: u64,
    last_scancode: u8,
    shift_held: bool,
    alt_held: bool,
    keymap: Keymap,
}

impl Ps2Driver {
    fn match_scancode(&mut self, key: u8, is_release: bool, scancode: u8) {
        match scancode {
            0x2A | 0x36 => self.shift_held = true,
            0xAA | 0xB6 => self.shift_held = false,
            0x38 => self.alt_held = true,
            0xB8 => self.alt_held = false,
            _ => {
                if !is_release {
                    let table = if self.alt_held {
                        match self.keymap {
                            Keymap::US => &QWERTY_ALT,
                            Keymap::DE => &QWERTZ_ALT,
                        }
                    } else if self.shift_held {
                        match self.keymap {
                            Keymap::US => &QWERTY_SHIFT,
                            Keymap::DE => &QWERTZ_SHIFT,
                        }
                    } else {
                        match self.keymap {
                            Keymap::US => &QWERTY_NORMAL,
                            Keymap::DE => &QWERTZ_NORMAL,
                        }
                    };
                    if let Some(&c) = table.get(key as usize) {
                        for subscriber in self.subscribers.iter() {
                            create_ipc_task(
                                self.pid,
                                *subscriber,
                                IpcData::Payload(Box::new(c)),
                            );
                        }
                        if c != '\0' {
                            crate::klog::log(
                                self.name,
                                &format!("Char: {c}"),
                                crate::klog::MessageType::Info,
                            );
                        }
                    }
                }
            }
        }
    }
}

impl crate::proc::Process for Ps2Driver {
    fn new() -> Box<Self> {
        Box::new(Self {
            name: "PS/2 Driver",
            pid: 0,
            status: ProcessStatus::Running,

            subscribers: Vec::new(),
            ticks: 0,
            last_scancode: 0,
            shift_held: false,
            alt_held: false,
            keymap: Keymap::US,
        })
    }
    fn name(&self) -> &'static str {
        "PS/2 Driver"
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
        unsafe {
            #[allow(const_item_mutation)]
            {
                STAT_PORT.write(0xAD);
                STAT_PORT.write(0xA7);
                while STAT_PORT.read() & 0x1 != 0 {
                    let _ = DATA_PORT.read();
                }
                STAT_PORT.write(0xAE);
            }
        }
    }
    fn on_tick(&mut self) -> Result<ProcessEvent, crate::proc::ProcessError> {
        self.ticks += 1;
        if !self.ticks.is_multiple_of(10_000) {
            return Ok(ProcessEvent::Yielded)
        }
        #[allow(const_item_mutation)]
        if unsafe { STAT_PORT.read() } & 0x1 != 0 {
            #[allow(const_item_mutation)]
            let scancode = unsafe { DATA_PORT.read() };
            let is_release = scancode & 0x80 != 0;
            let key = scancode & 0x7F;
            if scancode != self.last_scancode {
                self.last_scancode = scancode;
                self.match_scancode(key, is_release, scancode);
            }
            self.last_scancode = scancode;
        }
        Ok(ProcessEvent::Yielded)
    }
    fn on_uninit(self: Box<Self>) {}
    fn receive(&mut self, _data: IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }
    fn bind(&mut self, subscriber: u32) {
        self.subscribers.push(subscriber);
        crate::klog::log(
            self.name,
            &format!("Added subscriber: {}", subscriber),
            crate::klog::MessageType::Info,
        );
    }
}

pub enum Keymap {
    DE,
    US,
}