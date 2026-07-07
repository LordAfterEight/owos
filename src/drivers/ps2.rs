pub const KEY_UP: char = '\u{F800}';
pub const KEY_DOWN: char = '\u{F801}';
pub const KEY_SHIFT_UP: char = '\u{F802}';
pub const KEY_SHIFT_DOWN: char = '\u{F803}';
pub const KEY_LEFT: char = '\u{F804}';
pub const KEY_RIGHT: char = '\u{F805}';
pub const KEY_F1: char = '\u{F810}';
pub const KEY_F2: char = '\u{F811}';
pub const KEY_F3: char = '\u{F812}';

const MAX_BYTES_PER_TICK: u32 = 16;

pub const DATA_PORT: u16 = 0x60;
pub const STAT_PORT: u16 = 0x64;

// Bit 6 enables set-2→set-1 translation in the 8042. Must stay OFF when the
// keyboard is already configured to emit set 1, otherwise bytes get translated
// twice (e.g. set-1 0x21 "f" becomes 0x2E "c", set-1 0x0E backspace becomes 0x29 "`").
const CFG_TRANSLATION: u8 = 1 << 6;

pub fn read_status() -> u8 {
    crate::io::inb(STAT_PORT)
}

pub fn read_data() -> u8 {
    crate::io::inb(DATA_PORT)
}

pub fn write_cmd(cmd: u8) {
    wait_input_empty();
    crate::io::outb(STAT_PORT, cmd);
}

pub fn write_data(data: u8) {
    wait_input_empty();
    crate::io::outb(DATA_PORT, data);
}

pub fn wait_input_empty() {
    for _ in 0..100_000 {
        if read_status() & 0x02 == 0 {
            return;
        }
    }
}

pub fn wait_output_full() {
    for _ in 0..100_000 {
        if read_status() & 0x01 != 0 {
            return;
        }
    }
}

pub fn flush_output() {
    for _ in 0..32 {
        if read_status() & 0x01 == 0 {
            break;
        }
        let _ = read_data();
    }
}

pub fn configure_controller() {
    write_cmd(0xAD);
    write_cmd(0xA7);
    flush_output();

    write_cmd(0x20);
    wait_output_full();
    let mut cfg = read_data();
    cfg &= !CFG_TRANSLATION;
    cfg &= !(1 << 4);
    cfg &= !(1 << 5);

    write_cmd(0x60);
    write_data(cfg);

    write_cmd(0xAE);
    write_cmd(0xA8);
    flush_output();
}

pub fn keyboard_set_scancode_set1() {
    write_data(0xF0);
    wait_output_full();
    let _ = read_data();
    write_data(0x01);
    wait_output_full();
    let _ = read_data();
    flush_output();
}

pub fn keyboard_init() {
    configure_controller();
    keyboard_set_scancode_set1();
    flush_output();
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Keymap {
    Us,
    De,
}

static KEYMAP: spin::Mutex<Keymap> = spin::Mutex::new(Keymap::Us);

pub fn set_keymap(map: Keymap) {
    *KEYMAP.lock() = map;
}

pub fn keymap() -> Keymap {
    *KEYMAP.lock()
}

pub struct Ps2Driver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
    subscribers: alloc::vec::Vec<u32>,
    awaiting_extended: bool,
    awaiting_break: bool,
    shift_count: u8,
    alt_held: bool,
    altgr_held: bool,
}

impl crate::proc::Process for Ps2Driver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "PS/2 Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
            subscribers: alloc::vec::Vec::new(),
            awaiting_extended: false,
            awaiting_break: false,
            shift_count: 0,
            alt_held: false,
            altgr_held: false,
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
        keyboard_init();
    }
    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        let mut bytes = 0u32;
        loop {
            if bytes >= MAX_BYTES_PER_TICK {
                break;
            }
            let status = read_status();
            if status & 0x01 == 0 || status & 0x20 != 0 {
                break;
            }
            let scancode = read_data();
            self.handle_scancode(scancode);
            bytes += 1;
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }
    fn on_uninit(self: alloc::boxed::Box<Self>) {}
    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
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

fn extended_char(key: u8, shift: bool) -> Option<char> {
    match (key, shift) {
        (0x48, true) => Some(KEY_SHIFT_UP),
        (0x48, false) => Some(KEY_UP),
        (0x50, true) => Some(KEY_SHIFT_DOWN),
        (0x50, false) => Some(KEY_DOWN),
        (0x4B, _) => Some(KEY_LEFT),
        (0x4D, _) => Some(KEY_RIGHT),
        _ => None,
    }
}

fn function_char(key: u8) -> Option<char> {
    match key {
        0x3B => Some(KEY_F1),
        0x3C => Some(KEY_F2),
        0x3D => Some(KEY_F3),
        _ => None,
    }
}

impl Ps2Driver {
    fn shift_held(&self) -> bool {
        self.shift_count > 0
    }

    fn set_shift(&mut self, pressed: bool) {
        if pressed {
            self.shift_count = self.shift_count.saturating_add(1);
        } else {
            self.shift_count = self.shift_count.saturating_sub(1);
        }
    }

    fn lookup_keymap(&self, key: u8) -> Option<char> {
        let map = keymap();
        let table = if self.alt_held || self.altgr_held {
            match map {
                Keymap::Us => &crate::res::keymaps::QWERTY_ALT,
                Keymap::De => &crate::res::keymaps::QWERTZ_ALT,
            }
        } else if self.shift_held() {
            match map {
                Keymap::Us => &crate::res::keymaps::QWERTY_SHIFT,
                Keymap::De => &crate::res::keymaps::QWERTZ_SHIFT,
            }
        } else {
            match map {
                Keymap::Us => &crate::res::keymaps::QWERTY_NORMAL,
                Keymap::De => &crate::res::keymaps::QWERTZ_NORMAL,
            }
        };
        table.get(key as usize).copied().filter(|c| *c != '\0')
    }

    fn handle_scancode(&mut self, scancode: u8) {
        if scancode == 0xE0 {
            self.awaiting_extended = true;
            return;
        }
        if scancode == 0xF0 {
            self.awaiting_break = true;
            return;
        }
        let is_release = self.awaiting_break || scancode & 0x80 != 0;
        self.awaiting_break = false;
        let key = scancode & 0x7F;
        let mut extended = false;
        if self.awaiting_extended {
            self.awaiting_extended = false;
            extended = true;
            if key == 0x38 {
                self.altgr_held = !is_release;
                return;
            }
            if !is_release {
                if let Some(c) = extended_char(key, self.shift_held()) {
                    self.emit_key(c);
                    return;
                }
            } else {
                return;
            }
        }
        match key {
            0x2A | 0x36 => self.set_shift(!is_release),
            0x38 if !extended => self.alt_held = !is_release,
            0x3B..=0x3D if !extended => {
                if !is_release {
                    if let Some(c) = function_char(key) {
                        self.emit_key(c);
                    }
                }
            }
            _ => {
                if !is_release {
                    if let Some(c) = self.lookup_keymap(key) {
                        self.emit_key(c);
                    }
                }
            }
        }
    }

    fn emit_key(&self, c: char) {
        let focused_pid = crate::kui::window::WINDOW_MANAGER
            .lock()
            .focused_owner_pid();
        let targets = if let Some(pid) = focused_pid {
            if self.subscribers.iter().any(|subscriber| *subscriber == pid) {
                alloc::vec![pid]
            } else {
                self.subscribers.clone()
            }
        } else {
            self.subscribers.clone()
        };
        for subscriber in targets {
            crate::proc::create_ipc_task(
                self.pid,
                subscriber,
                crate::proc::IpcData::Payload(alloc::boxed::Box::new(c)),
            );
        }
    }
}