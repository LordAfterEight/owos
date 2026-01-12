#include "bitmap_font.h"
#include "rendering.h"
#include "std.h"

const int SCREEN_WIDTH = 1280;
const int SCREEN_HEIGHT = 720;

void blit_pixel(uint32_t* fb_ptr, int x, int y, uint32_t color) {
    if (x >= 0 && x < SCREEN_WIDTH && y >= 0 && y < SCREEN_HEIGHT) {
        fb_ptr[y * SCREEN_WIDTH + x] = color;
    }
}

void draw_rect_f(uint32_t* fb_ptr, int x, int y, int w, int h, uint32_t color) {
    for (int pixel_y = 0; pixel_y <= h; pixel_y++) {
        for (int pixel_x = 0; pixel_x <= w; pixel_x++) {
            blit_pixel(fb_ptr, x + pixel_x, y + pixel_y, color);
        }
    }
}

void draw_text(uint32_t* fb_ptr, int x, int y, const char* text, uint32_t color, bool inverse) {
    int char_offset = 0;
    for (size_t i = 0; text[i] != '\0'; i++) {
        const uint8_t* bitmap = get_bitmap(text[i]);
        for (int char_y = 0; char_y < 7; char_y++) {
            for (int char_x = 0; char_x < 7; char_x++) {
                bool pixel_on = (bitmap[char_y] & (1 << char_x)) != 0;

                if (pixel_on != inverse) {
                    blit_pixel(fb_ptr, x + (char_x + char_offset), y + char_y, color);
                }
            }
        }
        char_offset += 7;
    }
}

void draw_char(uint32_t* fb_ptr, int x, int y, const char character, uint32_t color, bool inverse) {
    const uint8_t* bitmap = get_bitmap(character);
    for (int char_y = 0; char_y < 8; char_y++) {
        for (int char_x = 7; char_x > 0; char_x--) {              // left → right
            // Bit 7 = leftmost pixel (MSB)
            bool pixel_on = (bitmap[char_y] & (1 << (7 - char_x))) != 0;

            // Draw only when we should (normal or inverted)
            if (pixel_on != inverse) {
                blit_pixel(fb_ptr, x + char_x*-1, y + char_y, color);
            }
        }
    }
}
