#include <stdint.h>
#include "std/std.h"

#define PS2_DATA_PORT    0x60
#define PS2_STATUS_PORT  0x64

static const char unshifted_map[128];

static const char shifted_map[128];

char map_scancode(uint8_t scancode, uint8_t is_shifted);
char handle_keyboard_input(uint8_t scancode);
char getchar_polling(void);
