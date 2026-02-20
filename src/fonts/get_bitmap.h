#ifndef GET_BITMAP
#define GET_BITMAP

#include <stdint.h>
#include "font.h"

const uint8_t* get_bitmap(char c, const struct Font* font);

#endif
