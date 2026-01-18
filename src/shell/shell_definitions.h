#ifndef SHELL_H
#define SHELL_H

#include "rendering.h"
#include "drivers/ps2.h"
#include "timer.h"
#include "fonts/font.h"

struct CommandBuffer {
    char buffer[16][256];
    int nth_command;
    int buffer_pos;
};

struct Cursor {
    int pos_x;
    int pos_y;
    bool visible;
    unsigned long last_toggle;
};

struct Shell {
    struct CommandBuffer buffer;
    struct Cursor cursor;
};

void push_char(struct CommandBuffer* buffer, const char character);
void move_cursor(struct Cursor* cursor, uint8_t value);
void shell_print(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font);
void shell_println(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font);
void handle_input(struct Shell* shell, char* input);
void update_buffer(struct Shell* shell);
void update_cursor(struct Shell* shell);
void update_shell(struct Shell* shell);
void clear_screen(struct Shell* shell);

#endif
