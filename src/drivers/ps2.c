#include <stdint.h>
#include "../std/std.h"
#include "ps2.h"

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



static mouse_state_t mouse_state = {0};
static uint8_t mouse_cycle = 0;
static uint8_t mouse_packet[3];

void handle_mouse_packet(void) {
    uint8_t status = mouse_packet[0];

    mouse_state.buttons = status & 0x07;

    int16_t rel_x = mouse_packet[1];
    int16_t rel_y = mouse_packet[2];

    if (status & 0x10) rel_x |= 0xFF00;
    if (status & 0x20) rel_y |= 0xFF00;

    mouse_state.x += rel_x;
    mouse_state.y -= rel_y;

    // Clamp to screen bounds
    if (mouse_state.x < 0) mouse_state.x = 0;
    if (mouse_state.y < 0) mouse_state.y = 0;
    if (mouse_state.x >= mouse_state.screen_width)
        mouse_state.x = mouse_state.screen_width - 1;
    if (mouse_state.y >= mouse_state.screen_height)
        mouse_state.y = mouse_state.screen_height - 1;
}



char map_scancode(uint8_t scancode, uint8_t is_shifted) {
    if (scancode >= 128) return 0;
    return is_shifted ? shifted_map[scancode] : unshifted_map[scancode];
}

void ps2_wait_write(void) {
    while (inb(PS2_STATUS_PORT) & 0x02);
}

void ps2_wait_read(void) {
    while (!(inb(PS2_STATUS_PORT) & 0x01));
}

void ps2_write_command(uint8_t cmd) {
    ps2_wait_write();
    outb(PS2_STATUS_PORT, cmd);
}

void ps2_write_data(uint8_t data) {
    ps2_wait_write();
    outb(PS2_DATA_PORT, data);
}

uint8_t ps2_read_data(void) {
    ps2_wait_read();
    return inb(PS2_DATA_PORT);
}

void ps2_mouse_init(void) {
    uint8_t status;

    ps2_write_command(0xAD);
    ps2_write_command(0xA7);

    while (inb(PS2_STATUS_PORT) & 0x01) {
        inb(PS2_DATA_PORT);
    }

    ps2_write_command(0x20);
    status = ps2_read_data();

    status |= 0x01;
    status &= ~0x20;
    status &= ~0x10;

    ps2_write_command(0x60);
    ps2_write_data(status);

    ps2_write_command(0xA8);

    ps2_write_command(0xD4);
    ps2_write_data(0xFF);

    uint8_t resp = ps2_read_data();
    resp = ps2_read_data();
    resp = ps2_read_data();

    ps2_write_command(0xD4);
    ps2_write_data(0xF4);

    resp = ps2_read_data();

    ps2_write_command(0xAE);
}


mouse_state_t* ps2_get_mouse_state(void) {
    return &mouse_state;
}

void ps2_set_screen_bounds(uint16_t width, uint16_t height) {
    mouse_state.screen_width = width;
    mouse_state.screen_height = height;
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

char ps2_poll(void) {
    if (!(inb(PS2_STATUS_PORT) & 0x01)) {
        return 0;
    }

    uint8_t status = inb(PS2_STATUS_PORT);
    uint8_t data = inb(PS2_DATA_PORT);


    if (status & 0x20) {
        mouse_packet[mouse_cycle++] = data;
        if (mouse_cycle == 3) {
            mouse_cycle = 0;
            handle_mouse_packet();
        }
        return 0;
    } else {
        return handle_keyboard_input(data);
    }
}
