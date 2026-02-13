#ifndef RENDERING_H
#define RENDERING_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#include "fonts/font.h"

extern const uint32_t SCREEN_WIDTH;
extern const uint32_t SCREEN_HEIGHT;

extern volatile uint32_t* global_framebuffer;
extern volatile uint64_t draw_rsp_mod16;

void blit_pixel(uint32_t x, uint32_t y, uint32_t color);
void draw_rect_f(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color);
void draw_text(uint32_t x, uint32_t y, const char* text, uint32_t color, bool inverse, const struct Font* font);
int draw_text_wrapping(uint32_t x, uint32_t y, const char* text, uint32_t color, bool inverse, const struct Font* font);
void draw_char(uint32_t x, uint32_t y, const char character, uint32_t color, bool inverse, const struct Font* font);

#endif
