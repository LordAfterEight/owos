#include "rendering.h"
#include "drivers/ps2.h"
#include "timer.h"
#include "idt.h"
#include "shell_definitions.h"
#include "fonts/OwOSFont_8x8.h"
#include "fonts/OwOSFont_8x16.h"

void push_char(struct InputBuffer* buffer, const char character) {
    buffer->buffer[buffer->buffer_pos] = character;
    buffer->buffer_pos++;
}

void move_cursor(struct Cursor* cursor, int8_t value) {
    cursor->pos_x += value;
}

void shell_print(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font) {
    shell->cursor.pos_y += draw_text_wrapping(shell->cursor.pos_x, shell->cursor.pos_y, text, color, invert, font);
    move_cursor(&shell->cursor, strlen(text) * font->width);
}

void shell_println(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font) {
    shell_print(shell, text, color, invert, font);
    if (!(shell->cursor.pos_y >= SCREEN_HEIGHT)) {
        shell->cursor.pos_y += font->height;
    } else {
        draw_rect_f(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0x000000);
        shell->cursor.pos_y = 1;
    }
    shell->cursor.pos_x = 1;
}

void handle_input(struct Shell* shell, char* input) {
    shell->cursor.pos_y += 16;
    shell->cursor.pos_x = 1;
    if (strcmp(input, "help")) {
        shell_println(shell, "General:", 0x77FF77, false, &OwOSFont_8x16);
        shell_println(shell, " - help: Prints this message", 0xAAAAAA, false, &OwOSFont_8x16);
        shell_println(shell, " - clear: Clears the screen", 0xAAAAAA, false, &OwOSFont_8x16);
        shell_println(shell, " - reboot: Reboots the PC", 0xAAAAAA, false, &OwOSFont_8x16);
        shell_println(shell, "", 0x000000, false, &OwOSFont_8x16);
        shell_println(shell, "Debugging/Testing:", 0x77FF77, false, &OwOSFont_8x16);
        shell_println(shell, " - panic: Causes a kernel panic, recoverable", 0xFFAAAA, false, &OwOSFont_8x16);
        shell_println(shell, " - irpt_enable: Enables interrupts", 0xFFFFAA, false, &OwOSFont_8x16);
        shell_println(shell, " - irpt_disable: Disables interrupts", 0xFFFFAA, false, &OwOSFont_8x16);
        shell_println(shell, " - idt_reinit: Reinitializes the Interrupt Descriptor Table", 0xFFFFAA, false, &OwOSFont_8x16);
        shell_println(shell, " - page_fault: Tests page fault handling, nonrecoverable", 0xFFFFAA, false, &OwOSFont_8x16);
        shell_println(shell, " - double_fault: Tests double fault handling, nonrecoverable", 0xFFFFAA, false, &OwOSFont_8x16);
    }
    else if (strcmp(input, "panic")) {
        shell->cursor.pos_x = 1;
        shell->cursor.pos_y = 1;
        panic(" Induced panic ");
    }
    else if (strcmp(input, "reboot")) {
        outb(0x64, 0xFE);
    }
    else if (strcmp(input, "clear")) {
        draw_rect_f(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0x000000);
        shell->cursor.pos_x = 1;
        shell->cursor.pos_y = 1;
    }
    else if (strcmp(input, "irpt_enable")) {
        asm volatile ("sti");
    }
    else if (strcmp(input, "irpt_disable")) {
        asm volatile ("cli");
    }
    else if (strcmp(input, "page_fault")) {
        set_idt_entry(14, page_fault_handler, 0, 0x8E);
        set_idt_entry(8, double_fault_handler, 1, 0x8E);
        *(volatile int*)0x123456789ABCDEF0 = 42;
    }
    else if (strcmp(input, "double_fault")) {
        set_idt_entry(14, page_fault_handler, 1, 0x8E);
        set_idt_entry(8, double_fault_handler, 0, 0x8E);
        *(volatile int*)0x123456789ABCDEF0 = 42;
    }
    else if (strcmp(input, "idt_reinit")) {
        idt_init();
        for (int y = 0; y < 32; y++) {
            for (int x = 0; x < 8; x++) {
                char buf[16];
                format(buf, "vector %d: 0x%x", x+8*y, idt[x+8*y]);
                draw_text(700 + x*150, 20 + y*16, buf, 0xFFAAAA, false, &OwOSFont_8x16);
            }
        }
    }
    else {
        if (!(strcmp(input, "\0"))) {
            char buf[64];
            format(buf, "Invalid command: %s", input);
            shell_println(shell, buf, 0xFFAAAA, false, &OwOSFont_8x16);
        }
    }
}

void update_buffer(struct Shell* shell) {
    char c = getchar_polling();
    if (c) {
        if (c == '\n' || c == '\r') {
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
            push_char(&shell->buffer, '\0');
            handle_input(shell, shell->buffer.buffer);
            memset(shell->buffer.buffer, 0, sizeof shell->buffer.buffer);
            shell->buffer.buffer_pos = 0;
            shell->cursor.pos_x = 1;
            shell_print(shell, "Command: ", 0xAAAAAA, false, &OwOSFont_8x16);
        } else if (c == '\b') {
            if (shell->cursor.pos_x != 0 && shell->buffer.buffer_pos != 0) {
                shell->buffer.buffer_pos -= 1;
                draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
                shell->cursor.pos_x -= 8;
                draw_char(shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.buffer_pos], 0x000000, false, &OwOSFont_8x16);
                shell->buffer.buffer[shell->buffer.buffer_pos] = 0;
            }
        } else {
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
            push_char(&shell->buffer, c);
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.buffer_pos - 1], 0xFFFFFF, false, &OwOSFont_8x16);
            move_cursor(&shell->cursor, 8);
        }
    }
}

void update_cursor(struct Cursor* cursor) {
    if (ticks - cursor->last_toggle >= 250) {
        cursor->last_toggle = ticks;
        cursor->visible = !cursor->visible;

        if (cursor->visible) {
            draw_char(cursor->pos_x, cursor->pos_y + 16, '^', 0xFFFFFF, false, &OwOSFont_8x16);
        } else {
            draw_char(cursor->pos_x, cursor->pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
        }
    }
}


void update_shell(struct Shell* shell) {
    update_cursor(&shell->cursor);
    update_buffer(shell);
}

