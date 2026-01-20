#include "rendering.h"
#include "std/mem.h"
#include "fonts/font.h"
#include "fonts/get_bitmap.h"

const int SCREEN_WIDTH = 1920;
const int SCREEN_HEIGHT = 1080;

volatile uint32_t* global_framebuffer = 0;

void blit_pixel(int x, int y, uint32_t color) {
    if (x >= 0 && x < SCREEN_WIDTH && y >= 0 && y < SCREEN_HEIGHT) {
        global_framebuffer[y * SCREEN_WIDTH + x] = color;
    }
}

void draw_rect_f(int x, int y, int w, int h, uint32_t color) {
    uint32_t* dst = global_framebuffer + y * SCREEN_WIDTH + x;
    for (int i = 0; i < h; i++) {
        memset(dst, color, w * sizeof(uint32_t));
        dst += SCREEN_WIDTH;
    }
}

void draw_text(int x, int y, const char* text, uint32_t color, bool inverse, const struct Font* font) {
    int char_offset = 0;
    for (size_t i = 0; text[i] != '\0'; i++) {
        const uint8_t* bitmap = get_bitmap(text[i], font);
        for (int char_y = 0; char_y < font->height; char_y++) {
            for (int char_x = 0; char_x < 8; char_x++) {
                bool pixel_on = (bitmap[char_y] & (0x80 >> char_x)) != 0;

                if (pixel_on != inverse) {
                    blit_pixel(x + (char_x + char_offset), y + char_y, color);
                }
            }
        }
        char_offset += 8;
    }
}

int draw_text_wrapping(int x, int y, const char* text, uint32_t color, bool inverse, const struct Font* font) {
    int x_offset = 0;
    int y_offset = 0;
    for (size_t i = 0; text[i] != '\0'; i++) {
        const uint8_t* bitmap = get_bitmap(text[i], font);
        for (int char_y = 0; char_y < font->height; char_y++) {
            for (int char_x = 0; char_x < 8; char_x++) {
                bool pixel_on = (bitmap[char_y] & (0x80 >> char_x)) != 0;

                if (pixel_on != inverse) {
                    blit_pixel(x + char_x + x_offset, y + char_y + y_offset, color);
                }
            }
        }
        if (x + x_offset >= SCREEN_WIDTH) {
            x_offset = 0;
            y_offset += font->height;
        } else {
            x_offset += 8;
        }
    }
    return y_offset;
}

void draw_char(int x, int y, const char character, uint32_t color, bool inverse, const struct Font* font) {
    const uint8_t* bitmap = get_bitmap(character, font);
    for (int char_y = 0; char_y < font->height; char_y++) {
        for (int char_x = 0; char_x < 8; char_x++) {
            bool pixel_on = (bitmap[char_y] & (0x80 >> char_x)) != 0;

            if (pixel_on != inverse) {
                blit_pixel(x + char_x, y + char_y, color);
            }
        }
    }
}
