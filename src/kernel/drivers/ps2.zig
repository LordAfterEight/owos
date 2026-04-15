const owos = @import("../root.zig");

const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn status() u8 {
    return inb(STATUS_PORT);
}

pub fn has_data() bool {
    return status() & 0x01 != 0;
}

pub fn read_data() u8 {
    return inb(DATA_PORT);
}

pub fn poll() ?u8 {
    if (has_data()) {
        return read_data();
    }
    return null;
}

// Scan code set 1 scancodes for modifier keys
const SC_LSHIFT: u8 = 0x2A;
const SC_RSHIFT: u8 = 0x36;
const SC_LALT: u8 = 0x38;
const SC_LCTRL: u8 = 0x1D;

// Modifier state
var shift_held: bool = false;
var alt_held: bool = false;
var ctrl_held: bool = false;

pub const Layout = enum {
    qwerty,
    qwertz,

    pub fn name(self: Layout) []const u8 {
        return switch (self) {
            .qwerty => "QWERTY",
            .qwertz => "QWERTZ",
        };
    }
};

pub var layout: Layout = .qwerty;

// Scan code set 1 → ASCII (unshifted, US QWERTY layout)
const qwerty_table = [128]u8{
    0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6', // 0x00-0x07
    '7',  '8',  '9',  '0',  '-',  '=',  0x08, '\t', // 0x08-0x0F
    'q',  'w',  'e',  'r',  't',  'y',  'u',  'i', // 0x10-0x17
    'o',  'p',  '[',  ']',  '\n', 0,    'a',  's', // 0x18-0x1F
    'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';', // 0x20-0x27
    '\'', '`',  0,    '\\', 'z',  'x',  'c',  'v', // 0x28-0x2F
    'b',  'n',  'm',  ',',  '.',  '/',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x40-0x47
    0,    0,    '-',  0,    0,    0,    '+',  0, // 0x48-0x4F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x50-0x57
    0,    0,    0,    0,    0,    0,    0,    0, // 0x58-0x5F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x60-0x67
    0,    0,    0,    0,    0,    0,    0,    0, // 0x68-0x6F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x70-0x77
    0,    0,    0,    0,    0,    0,    0,    0, // 0x78-0x7F
};

// Scan code set 1 → ASCII (shifted, US QWERTY layout)
const qwerty_shifted = [128]u8{
    0,    0x1B, '!',  '@',  '#',  '$',  '%',  '^', // 0x00-0x07
    '&',  '*',  '(',  ')',  '_',  '+',  0x08, '\t', // 0x08-0x0F
    'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I', // 0x10-0x17
    'O',  'P',  '{',  '}',  '\n', 0,    'A',  'S', // 0x18-0x1F
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  ':', // 0x20-0x27
    '"',  '~',  0,    '|',  'Z',  'X',  'C',  'V', // 0x28-0x2F
    'B',  'N',  'M',  '<',  '>',  '?',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x40-0x47
    0,    0,    '-',  0,    0,    0,    '+',  0, // 0x48-0x4F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x50-0x57
    0,    0,    0,    0,    0,    0,    0,    0, // 0x58-0x5F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x60-0x67
    0,    0,    0,    0,    0,    0,    0,    0, // 0x68-0x6F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x70-0x77
    0,    0,    0,    0,    0,    0,    0,    0, // 0x78-0x7F
};

// Scan code set 1 → ASCII (unshifted, German QWERTZ layout)
// Non-ASCII chars (ä, ö, ü, ß) map to 0
const qwertz_table = [128]u8{
    0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6', // 0x00-0x07
    '7',  '8',  '9',  '0',  0,    0,    0x08, '\t', // 0x08-0x0F (0x0C=ß, 0x0D=´)
    'q',  'w',  'e',  'r',  't',  'z',  'u',  'i', // 0x10-0x17 (y/z swapped)
    'o',  'p',  0,    '+',  '\n', 0,    'a',  's', // 0x18-0x1F (0x1A=ü)
    'd',  'f',  'g',  'h',  'j',  'k',  'l',  0, // 0x20-0x27 (0x27=ö)
    0,    '^',  0,    '#',  'y',  'x',  'c',  'v', // 0x28-0x2F (0x28=ä, y/z swapped)
    'b',  'n',  'm',  ',',  '.',  '-',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x40-0x47
    0,    0,    '-',  0,    0,    0,    '+',  0, // 0x48-0x4F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x50-0x57
    0,    0,    0,    0,    0,    0,    0,    0, // 0x58-0x5F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x60-0x67
    0,    0,    0,    0,    0,    0,    0,    0, // 0x68-0x6F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x70-0x77
    0,    0,    0,    0,    0,    0,    0,    0, // 0x78-0x7F
};

// Scan code set 1 → ASCII (shifted, German QWERTZ layout)
const qwertz_shifted = [128]u8{
    0,    0x1B, '!',  '"',  0,    '$',  '%',  '&', // 0x00-0x07 (0x04=§ non-ASCII)
    '/',  '(',  ')',  '=',  '?',  '`',  0x08, '\t', // 0x08-0x0F
    'Q',  'W',  'E',  'R',  'T',  'Z',  'U',  'I', // 0x10-0x17 (Y/Z swapped)
    'O',  'P',  0,    '*',  '\n', 0,    'A',  'S', // 0x18-0x1F
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  0, // 0x20-0x27
    0,    0,    0,    '\'', 'Y',  'X',  'C',  'V', // 0x28-0x2F (Y/Z swapped)
    'B',  'N',  'M',  ';',  ':',  '_',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x40-0x47
    0,    0,    '-',  0,    0,    0,    '+',  0, // 0x48-0x4F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x50-0x57
    0,    0,    0,    0,    0,    0,    0,    0, // 0x58-0x5F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x60-0x67
    0,    0,    0,    0,    0,    0,    0,    0, // 0x68-0x6F
    0,    0,    0,    0,    0,    0,    0,    0, // 0x70-0x77
    0,    0,    0,    0,    0,    0,    0,    0, // 0x78-0x7F
};

pub const KeyEvent = struct {
    char: ?u8,
    alt: bool,
    ctrl: bool = false,
    arrow_up: bool = false,
    arrow_down: bool = false,
    arrow_left: bool = false,
    arrow_right: bool = false,
    home: bool = false,
    end: bool = false,
    delete: bool = false,
};

// Extended scancode state (0xE0 prefix)
var e0_pending: bool = false;

// Extended scan codes (after 0xE0 prefix)
const EXT_ARROW_UP: u8 = 0x48;
const EXT_ARROW_DOWN: u8 = 0x50;
const EXT_ARROW_LEFT: u8 = 0x4B;
const EXT_ARROW_RIGHT: u8 = 0x4D;
const EXT_HOME: u8 = 0x47;
const EXT_END: u8 = 0x4F;
const EXT_DELETE: u8 = 0x53;

/// Process a scancode, updating modifier state and returning a KeyEvent.
/// Returns null for modifier-only keys and release events.
pub fn process(scancode: u8) ?KeyEvent {
    // Handle 0xE0 prefix for extended keys
    if (scancode == 0xE0) {
        e0_pending = true;
        return null;
    }

    if (e0_pending) {
        e0_pending = false;
        const released = scancode & 0x80 != 0;
        if (released) return null;
        const code = scancode & 0x7F;
        if (code == EXT_ARROW_UP) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .arrow_up = true };
        if (code == EXT_ARROW_DOWN) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .arrow_down = true };
        if (code == EXT_ARROW_LEFT) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .arrow_left = true };
        if (code == EXT_ARROW_RIGHT) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .arrow_right = true };
        if (code == EXT_HOME) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .home = true };
        if (code == EXT_END) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .end = true };
        if (code == EXT_DELETE) return .{ .char = null, .alt = alt_held, .ctrl = ctrl_held, .delete = true };
        return null; // ignore other extended keys for now
    }

    const released = scancode & 0x80 != 0;
    const code = scancode & 0x7F;

    // Update modifier state
    if (code == SC_LSHIFT or code == SC_RSHIFT) {
        shift_held = !released;
        return null;
    }
    if (code == SC_LALT) {
        alt_held = !released;
        return null;
    }
    if (code == SC_LCTRL) {
        ctrl_held = !released;
        return null;
    }

    if (released) return null;

    const table = switch (layout) {
        .qwerty => if (shift_held) &qwerty_shifted else &qwerty_table,
        .qwertz => if (shift_held) &qwertz_shifted else &qwertz_table,
    };
    const c = table[code];
    if (c == 0) return null;

    return .{ .char = c, .alt = alt_held, .ctrl = ctrl_held };
}

/// Simple wrapper: process a scancode and return just the character (ignoring modifiers).
pub fn to_char(scancode: u8) ?u8 {
    const event = process(scancode) orelse return null;
    return event.char;
}

pub fn init() void {
    // Disable both PS/2 ports during setup
    outb(STATUS_PORT, 0xAD);
    outb(STATUS_PORT, 0xA7);

    // Flush the output buffer
    while (has_data()) {
        _ = read_data();
    }

    // Enable keyboard port
    outb(STATUS_PORT, 0xAE);

    owos.klog.info("PS2: keyboard controller initialized", .{});
    owos.fb.rendering.swap();
}
