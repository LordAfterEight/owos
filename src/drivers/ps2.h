#include <stdint.h>
#include "../std/std.h"

#define PS2_DATA_PORT    0x60
#define PS2_STATUS_PORT  0x64

typedef struct {
    int16_t x;
    int16_t y;
    uint8_t buttons;
    uint16_t screen_width;
    uint16_t screen_height;
} mouse_state_t;

static const char unshifted_map[128];
static mouse_state_t mouse_state;
static const char shifted_map[128];

char map_scancode(uint8_t scancode, uint8_t is_shifted);
char handle_keyboard_input(uint8_t scancode);
void handle_mouse_packet(void);
void ps2_wait_write(void);
void ps2_wait_read(void);
void ps2_write_command(uint8_t cmd);
void ps2_write_data(uint8_t data);
uint8_t ps2_read_data(void);
void ps2_mouse_init(void);
mouse_state_t* ps2_get_mouse_state(void);
void ps2_set_screen_bounds(uint16_t width, uint16_t height);
char ps2_poll(void);
