#include "rendering.h"
#include "keyboard.h"

struct InputBuffer {
    char buffer[256];
    int buffer_pos;
};

struct Cursor {
    int pos_x;
    int pos_y;
    bool visible;
    volatile unsigned long counter;
    const unsigned long threshold;
};

struct Shell {
    struct InputBuffer buffer;
    struct Cursor cursor;
};

void push_char(struct InputBuffer* buffer, const char character) {
    buffer->buffer[buffer->buffer_pos] = character;
    buffer->buffer_pos++;
}

void move_cursor(struct Cursor* cursor, int8_t value) {
    cursor->pos_x += value;
}

void shell_print(uint32_t* framebuffer, struct Shell* shell, char* text, uint32_t color, bool invert) {
    draw_text(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y, text, color, invert);
    move_cursor(&shell->cursor, (strlen(text) + 1) * 7);
}

void shell_println(uint32_t* framebuffer, struct Shell* shell, char* text, uint32_t color, bool invert) {
    shell_print(framebuffer, shell, text, color, invert);
    shell->cursor.pos_y += 10;
    shell->cursor.pos_x = 1;
}

void handle_input(uint32_t* framebuffer, struct Shell* shell, char* input) {
    shell->cursor.pos_y += 10;
    shell->cursor.pos_x = 1;
    if (strcmp(input, "help")) {
        shell_println(framebuffer, shell, " - help: prints this message", 0xAAAAAA, false);
        shell_println(framebuffer, shell, " - clear: clears the screen", 0xAAAAAA, false);
        shell_println(framebuffer, shell, " - panic: makes the kernel panic", 0xFFAAAA, false);
        shell_println(framebuffer, shell, " - reboot: reboots the PC", 0xAAAAAA, false);
    }
    else if (strcmp(input, "panic")) {
        panic(framebuffer, " Induced panic ");
    }
    else if (strcmp(input, "reboot")) {
        outb(0x64, 0xFE);
    }
    else if (strcmp(input, "clear")) {
        draw_rect_f(framebuffer, 0, 0, SCREEN_WIDTH - 1, SCREEN_HEIGHT - 1, 0x000000);
        shell->cursor.pos_x = 1;
        shell->cursor.pos_y = 1;
    }
    else {
        if (strcmp(input, "\0") != true) {
            shell_print(framebuffer, shell, "Invalid command: ", 0xFFAAAA, false);
            shell_println(framebuffer, shell, input, 0xAAAAAA, false);
        }
    }
}

void update_buffer(uint32_t* framebuffer, struct Shell* shell) {
    char c = getchar_polling();
    if (c) {
        if (c == '\n' || c == '\r') {
            push_char(&shell->buffer, '\0');
            draw_char(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y + 10, '^', 0x000000, false);
            handle_input(framebuffer, shell, shell->buffer.buffer);
            memset(shell->buffer.buffer, 0, sizeof shell->buffer.buffer);
            shell->buffer.buffer_pos = 0;
            shell->cursor.pos_x = 1;
            shell_print(framebuffer, shell, "Command: ", 0xAAAAAA, false);
        } else if (c == '\b') {
            if (shell->cursor.pos_x != 0 && shell->buffer.buffer_pos != 0) {
                shell->buffer.buffer_pos -= 1;
                draw_char(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y + 10, '^', 0x000000, false);
                shell->cursor.pos_x -= 7;
                draw_char(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.buffer_pos], 0x000000, false);
                shell->buffer.buffer[shell->buffer.buffer_pos] = 0;
            }
        } else {
            push_char(&shell->buffer, c);
            draw_char(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y + 10, '^', 0x000000, false);
            draw_char(framebuffer, shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.buffer_pos - 1], 0xFFFFFF, false);
            move_cursor(&shell->cursor, 7);
        }
    }
}

void update_cursor(uint32_t* framebuffer, struct Cursor* cursor) {
    cursor->counter++;
    if (cursor->counter >= cursor->threshold) {
        cursor->counter = 0;
        cursor->visible = !cursor->visible;

        if (cursor->visible) {
            draw_char(framebuffer, cursor->pos_x, cursor->pos_y + 10, '^', 0xFFFFFF, false);
        } else {
            draw_char(framebuffer, cursor->pos_x, cursor->pos_y + 10, '^', 0x000000, false);
        }
    }
}


void update_shell(uint32_t* framebuffer, struct Shell* shell) {
    update_buffer(framebuffer, shell);
    update_cursor(framebuffer, &shell->cursor);
}

