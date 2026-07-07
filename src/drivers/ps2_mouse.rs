use crate::drivers::ps2::{
    flush_output, read_data as ps2_read_data, read_status as ps2_read_status, wait_output_full,
    write_cmd, write_data,
};

const MAX_BYTES_PER_TICK: u32 = 32;

#[derive(Clone, Copy, Debug)]
pub struct MouseEvent {
    pub dx: i32,
    pub dy: i32,
    pub buttons: u8,
}

pub struct Ps2MouseDriver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
    subscribers: alloc::vec::Vec<u32>,
    packet: [u8; 3],
    packet_index: u8,
    pending_dx: i32,
    pending_dy: i32,
    pending_buttons: u8,
    buttons_dirty: bool,
}

impl crate::proc::Process for Ps2MouseDriver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "PS/2 Mouse",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
            subscribers: alloc::vec::Vec::new(),
            packet: [0; 3],
            packet_index: 0,
            pending_dx: 0,
            pending_dy: 0,
            pending_buttons: 0,
            buttons_dirty: false,
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
        init_mouse();
        crate::drivers::ps2::keyboard_init();
        if let Some(compositor_pid) = crate::proc::registry::PROCESS_TABLE
            .lock()
            .iter()
            .find(|entry| entry.name == "Compositor")
            .map(|entry| entry.pid)
        {
            crate::proc::create_binding_task(compositor_pid, self.pid);
        }
    }

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        let mut bytes = 0u32;
        loop {
            if bytes >= MAX_BYTES_PER_TICK {
                break;
            }
            let status = ps2_read_status();
            if status & 0x01 == 0 || status & 0x20 == 0 {
                break;
            }
            let byte = ps2_read_data();
            bytes += 1;
            if self.packet_index == 0 && byte & 0x08 == 0 {
                continue;
            }

            self.packet[self.packet_index as usize] = byte;
            self.packet_index += 1;
            if self.packet_index < 3 {
                continue;
            }
            self.packet_index = 0;

            self.pending_dx += self.packet[1] as i8 as i32;
            self.pending_dy += -(self.packet[2] as i8 as i32);
            let buttons = self.packet[0] & 0x07;
            if buttons != self.pending_buttons {
                self.pending_buttons = buttons;
                self.buttons_dirty = true;
            }
        }

        if self.pending_dx != 0 || self.pending_dy != 0 || self.buttons_dirty {
            let event = MouseEvent {
                dx: self.pending_dx,
                dy: self.pending_dy,
                buttons: self.pending_buttons,
            };
            self.emit(event);
            self.pending_dx = 0;
            self.pending_dy = 0;
            self.buttons_dirty = false;
        }

        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }
    fn bind(&mut self, subscriber: u32) {
        self.subscribers.push(subscriber);
    }
}

impl Ps2MouseDriver {
    fn emit(&self, event: MouseEvent) {
        for subscriber in &self.subscribers {
            crate::proc::create_ipc_task(
                self.pid,
                *subscriber,
                crate::proc::IpcData::Payload(alloc::boxed::Box::new(event)),
            );
        }
    }
}

fn write_mouse(data: u8) {
    write_cmd(0xD4);
    write_data(data);
}

fn read_mouse_ack() -> u8 {
    wait_output_full();
    ps2_read_data()
}

fn init_mouse() {
    crate::drivers::ps2::configure_controller();

    write_mouse(0xFF);
    let _ = read_mouse_ack();
    let _ = read_mouse_ack();
    let _ = read_mouse_ack();

    write_mouse(0xF6);
    let _ = read_mouse_ack();

    write_mouse(0xF4);
    let _ = read_mouse_ack();

    flush_output();
}