#ifndef SHELL_H
#define SHELL_H

#include "rendering.h"
#include "drivers/ps2.h"
#include "timer.h"
#include "fonts/font.h"
#include "process/process.h"

struct CommandBuffer {
    char buffer[16][256];
    int nth_command;
    int buffer_pos;
};

struct Cursor {
    int pos_x;
    int pos_y;
    bool visible;
    uint32_t last_toggle;
};

struct Shell {
    struct CommandBuffer buffer;
    struct Cursor cursor;
};

extern volatile struct CommandBuffer command_buffer;
extern volatile struct Cursor cursor;
extern volatile struct Shell shell;
extern volatile struct Process shell_process;

void shell_init();
void push_char(struct CommandBuffer* buffer, const char character);
void move_cursor(struct Cursor* cursor, uint8_t value);
void shell_print(char* text, uint32_t color, bool invert, const struct Font* font);
void shell_println(char* text, uint32_t color, bool invert, const struct Font* font);
int handle_input(char* input);
int update_buffer();
void update_cursor();
int update_shell();
void clear_screen();
int start_shell();
void greet();

#endif
