pub const KEY_UP: char = '\u{F800}';
pub const KEY_DOWN: char = '\u{F801}';
pub const KEY_SHIFT_UP: char = '\u{F802}';
pub const KEY_SHIFT_DOWN: char = '\u{F803}';

pub const DATA_PORT: x86_64::instructions::port::Port<u8> =
    x86_64::instructions::port::Port::new(0x60);
pub const STAT_PORT: x86_64::instructions::port::Port<u8> =
    x86_64::instructions::port::Port::new(0x64);

pub struct Ps2Driver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    subscribers: alloc::vec::Vec<u32>,
    ticks: u64,
    last_scancode: u8,
    awaiting_extended: bool,
    shift_held: bool,
    alt_held: bool,
    keymap: Keymap,
}

impl crate::proc::Process for Ps2Driver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "PS/2 Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            subscribers: alloc::vec::Vec::new(),
            ticks: 0,
            last_scancode: 0,
            awaiting_extended: false,
            shift_held: false,
            alt_held: false,
            keymap: Keymap::DE,
        })
    }
    fn name(&self) -> &'static str {
        "PS/2 Driver"
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
        unsafe {
            STAT_PORT.write(0xAD);
            STAT_PORT.write(0xA7);

            while STAT_PORT.read() & 0x1 != 0 {
                let _ = DATA_PORT.read();
            }

            STAT_PORT.write(0xAE);
        }
    }
    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        self.ticks += 1;
        if self.ticks.is_multiple_of(10_000) {
            if unsafe { STAT_PORT.read() } & 0x1 != 0 {
                let scancode = unsafe { DATA_PORT.read() };
                let is_release = scancode & 0x80 != 0;
                let key = scancode & 0x7F;
                if scancode == 0xE0 {
                    self.awaiting_extended = true;
                } else if scancode != self.last_scancode {
                    if self.awaiting_extended {
                        self.awaiting_extended = false;
                        if !is_release {
                            if let Some(c) = extended_char(key, self.shift_held) {
                                self.emit_key(c);
                            }
                        }
                    } else {
                        match scancode {
                            0x2A | 0x36 => self.shift_held = true,
                            0xAA | 0xB6 => self.shift_held = false,
                            0x38 => self.alt_held = true,
                            0xB8 => self.alt_held = false,
                            _ => {
                                if !is_release {
                                    let table = if self.alt_held {
                                        match self.keymap {
                                            Keymap::US => &crate::res::keymaps::QWERTY_ALT,
                                            Keymap::DE => &crate::res::keymaps::QWERTZ_ALT,
                                        }
                                    } else if self.shift_held {
                                        match self.keymap {
                                            Keymap::US => &crate::res::keymaps::QWERTY_SHIFT,
                                            Keymap::DE => &crate::res::keymaps::QWERTZ_SHIFT,
                                        }
                                    } else {
                                        match self.keymap {
                                            Keymap::US => &crate::res::keymaps::QWERTY_NORMAL,
                                            Keymap::DE => &crate::res::keymaps::QWERTZ_NORMAL,
                                        }
                                    };
                                    if let Some(&c) = table.get(key as usize) {
                                        if c != '\0' {
                                            self.emit_key(c);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    self.last_scancode = scancode;
                }
                self.last_scancode = scancode;
            }
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }
    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }
    fn bind(&mut self, subscriber: u32) {
        self.subscribers.push(subscriber);
        crate::klog::log(
            self.name,
            &alloc::format!("Added subscriber: {}", subscriber),
            crate::klog::MessageType::Info,
        );
    }
}

struct Ps2Data {
    char: u8,
}

pub enum Keymap {
    DE,
    US,
}

fn extended_char(key: u8, shift: bool) -> Option<char> {
    match (key, shift) {
        (0x48, true) => Some(KEY_SHIFT_UP),
        (0x48, false) => Some(KEY_UP),
        (0x50, true) => Some(KEY_SHIFT_DOWN),
        (0x50, false) => Some(KEY_DOWN),
        _ => None,
    }
}

impl Ps2Driver {
    fn emit_key(&self, c: char) {
        for subscriber in self.subscribers.iter() {
            crate::proc::create_ipc_task(
                self.pid,
                *subscriber,
                crate::proc::IpcData::Payload(alloc::boxed::Box::new(c)),
            );
        }
        crate::klog::log(
            self.name,
            &alloc::format!("Key: {}", key_label(c)),
            crate::klog::MessageType::Info,
        );
    }
}

fn key_label(c: char) -> alloc::string::String {
    match c {
        KEY_UP => alloc::string::String::from("Up"),
        KEY_DOWN => alloc::string::String::from("Down"),
        KEY_SHIFT_UP => alloc::string::String::from("Shift+Up"),
        KEY_SHIFT_DOWN => alloc::string::String::from("Shift+Down"),
        '\n' => alloc::string::String::from("Enter"),
        '\t' => alloc::string::String::from("Tab"),
        '\x08' => alloc::string::String::from("Backspace"),
        c if c.is_control() => alloc::format!("Ctrl+{:?}", c),
        c => alloc::format!("'{c}'"),
    }
}

fn scancode_to_ascii(key: u8) -> Option<char> {
    crate::res::keymaps::QWERTZ_NORMAL
        .get(key as usize)
        .copied()
        .filter(|&b| b != 0 as char)
        .map(|b| b as char)
}
