#include <stdint.h>
#include "../std/std.h"

// Classic ports
#define PS2_DATA_PORT    0x60
#define PS2_STATUS_PORT  0x64

static const char unshifted_map[128] = {
    0,   0,   '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b', '\t',
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,   'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\','z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
};

static const char shifted_map[128] = {
    0,   0,   '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '\b', '\t',
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,   'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0,   '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
};

volatile uint8_t shift_pressed = 0;

char map_scancode(uint8_t scancode, uint8_t is_shifted) {
    if (scancode >= 128) return 0;
    return is_shifted ? shifted_map[scancode] : unshifted_map[scancode];
}

char handle_keyboard_input(uint8_t scancode) {
    if (scancode & 0x80) {
        uint8_t key = scancode & 0x7F;

        if (key == 0x2A || key == 0x36) {
            shift_pressed = 0;
        }

        return 0;
    }

    if (scancode == 0x2A || scancode == 0x36) {
        shift_pressed = 1;
        return 0;
    }

    char c = map_scancode(scancode, shift_pressed);
    return c;
}

char getchar_polling(void) {
    if (!(inb(PS2_STATUS_PORT) & 0x01)) {
        return 0;
    }

    uint8_t scancode = inb(PS2_DATA_PORT);
    return handle_keyboard_input(scancode);
}
