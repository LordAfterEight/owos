#ifndef RENDERING_H
#define RENDERING_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#include "fonts/font.h"

extern const int SCREEN_WIDTH;
extern const int SCREEN_HEIGHT;

extern volatile uint32_t* global_framebuffer;
extern volatile uint64_t draw_rsp_mod16;

void blit_pixel(int x, int y, uint32_t color);
void draw_rect_f(int x, int y, int w, int h, uint32_t color);
void draw_text(int x, int y, const char* text, uint32_t color, bool inverse, const struct Font* font);
int draw_text_wrapping(int x, int y, const char* text, uint32_t color, bool inverse, const struct Font* font);
void draw_char(int x, int y, const char character, uint32_t color, bool inverse, const struct Font* font);

#endif
