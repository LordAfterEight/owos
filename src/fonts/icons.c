#include <stdint.h>
#include "icons.h"
#include "font.h"

uint8_t IconBitmaps[] = {
    0b11000011,
    0b01100110,
    0b00111100,
    0b00011000,
    0b00111100,
    0b01100110,
    0b11000011,
    0b00000000,
};

struct Font IconFont = {
    name: "OwOSFont Regular 8x16px",
    bitmaps: IconBitmaps,
    width: 8,
    height: 8,
};

