#include <stdint.h>
#include "fonts/font.h"

const uint8_t* get_bitmap(char c, const struct Font* font) {
    if (c >= 32 && c <= 126) {
        return &font->bitmaps[c * font->height];
    }
    return &font->bitmaps[0];  // space
}
