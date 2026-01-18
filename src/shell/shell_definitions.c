#include "rendering.h"
#include "drivers/ps2.h"
#include "timer.h"
#include "idt.h"
#include "shell_definitions.h"
#include "fonts/OwOSFont_8x8.h"
#include "fonts/OwOSFont_8x16.h"
#include "sound/pcspeaker.h"
#include "time.h"

void push_char(struct CommandBuffer* buffer, const char character) {
    buffer->buffer[buffer->nth_command][buffer->buffer_pos] = character;
    buffer->buffer_pos++;
}

void move_cursor(struct Cursor* cursor, uint8_t value) {
    cursor->pos_x += value;
}

void shell_print(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font) {
    shell->cursor.pos_y += draw_text_wrapping(shell->cursor.pos_x, shell->cursor.pos_y, text, color, invert, font);
    move_cursor(&shell->cursor, strlen(text) * 8);
}

void shell_println(struct Shell* shell, char* text, uint32_t color, bool invert, const struct Font* font) {
    shell_print(shell, text, color, invert, font);
    shell->cursor.pos_y += font->height;
    shell->cursor.pos_x = 1;
}

void clear_screen(struct Shell* shell) {
    shell->cursor.pos_x = 1;
    shell->cursor.pos_y = 1;
    draw_rect_f(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0x000000);
    draw_rect_f(0, SCREEN_HEIGHT - 20, SCREEN_WIDTH, 20, 0x101010);
    char buf[32];
    format(buf, "OwOS-C v%s", KERNEL_VERSION);
    draw_text(5, SCREEN_HEIGHT - 18, buf, 0xAAAAAA, false, &OwOSFont_8x16);
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
        shell_println(shell, " - panic: Causes a kernel panic, recoverable", 0xFF7777, false, &OwOSFont_8x16);
        shell_println(shell, " - irpt enable: Enables interrupts", 0xFFFF77, false, &OwOSFont_8x16);
        shell_println(shell, " - irpt disable: Disables interrupts", 0xFFFF77, false, &OwOSFont_8x16);
        shell_println(shell, " - idt reinit: Reinitializes the Interrupt Descriptor Table", 0xFFFF77, false, &OwOSFont_8x16);
        shell_println(shell, " - idt check: Checks if all IDT entries are valid", 0x77FF77, false, &OwOSFont_8x16);
        shell_println(shell, " - page fault: Tests page fault handling, nonrecoverable", 0xFFFF77, false, &OwOSFont_8x16);
        shell_println(shell, " - double fault: Tests double fault handling, nonrecoverable", 0xFFFF77, false, &OwOSFont_8x16);
    }
    else if (strcmp(input, "panic")) {
        panic(" Induced panic ");
        clear_screen(shell);
    }
    else if (strcmp(input, "reboot")) {
        outb(0x64, 0xFE);
    }
    else if (strcmp(input, "clear")) {
        clear_screen(shell);
    }
    else if (strcmp(input, "info")) {
        shell_print(shell, "Kernel: ", 0xAAAAFF, false, &OwOSFont_8x16);
        char buf[32];
        format(buf, "OwOS-C v%s", KERNEL_VERSION);
        shell_println(shell, buf, 0x77FF77, false, &OwOSFont_8x16);
        shell_print(shell, "Build Date: ", 0xAAAAFF, false, &OwOSFont_8x16);
        shell_println(shell, __DATE__, 0x77FF77, false, &OwOSFont_8x16);
        shell_print(shell, "Developer: ", 0xAAAAFF, false, &OwOSFont_8x16);
        shell_println(shell, "Elias Stettmayer", 0x77FF77, false, &OwOSFont_8x16);
    }
    else if (strcmp(input, "irpt enable")) {
        asm volatile ("sti");
    }
    else if (strcmp(input, "irpt disable")) {
        asm volatile ("cli");
    }
    else if (strcmp(input, "page fault")) {
        set_idt_entry(14, page_fault_handler, 0, 0x8E);
        set_idt_entry(8, double_fault_handler, 1, 0x8E);
        *(volatile int*)0x123456789ABCDEF0 = 42;
    }
    else if (strcmp(input, "double fault")) {
        set_idt_entry(14, page_fault_handler, 1, 0x8E);
        set_idt_entry(8, double_fault_handler, 0, 0x8E);
        *(volatile int*)0x123456789ABCDEF0 = 42;
    }
    else if (strcmp(input, "idt reinit")) {
        idt_init();
        for (int y = 0; y < 32; y++) {
            for (int x = 0; x < 8; x++) {
                char buf[16];
                format(buf, "vector %d: 0x%x", x+8*y, idt[x+8*y]);
                draw_text(640 + x*160, 20 + y*16, buf, 0xFFAAAA, false, &OwOSFont_8x16);
            }
        }
    }
    else if (strcmp(input, "idt check")) {
        shell_print(shell, "[Kernel:IDT] -> ", 0xFFFFFF, false, &OwOSFont_8x16);
        if (check_idt_entry(32, timer_callback, 0, 0x8E)) {
            shell_println(shell, "Timer Callback [OK]", 0x22FF22, false, &OwOSFont_8x16);
        } else shell_println(shell, "Timer Callback [ERR]", 0xFF2222, false, &OwOSFont_8x16);
        shell_print(shell, "[Kernel:IDT] -> ", 0xFFFFFF, false, &OwOSFont_8x16);
        if (check_idt_entry(8, double_fault_handler, 1, 0x8E)) {
            shell_println(shell, "DF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
        } else shell_println(shell, "DF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);
        shell_print(shell, "[Kernel:IDT] -> ", 0xFFFFFF, false, &OwOSFont_8x16);
        if (check_idt_entry(14, page_fault_handler, 1, 0x8E)) {
            shell_println(shell, "PF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
        } else shell_println(shell, "PF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    }
    else {
        if (!(strcmp(input, "\0"))) {
            beep(950, 50);
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
            beep(1000, 25);
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
            push_char(&shell->buffer, '\0');
            handle_input(shell, shell->buffer.buffer[shell->buffer.nth_command]);
            memset(shell->buffer.buffer, 0, sizeof shell->buffer.buffer);
            shell->buffer.buffer_pos = 0;
            shell->cursor.pos_x = 1;
            shell_print(shell, "Command: ", 0xAAAAAA, false, &OwOSFont_8x16);
        } else if (c == '\b') {
            if (shell->cursor.pos_x != 0 && shell->buffer.buffer_pos != 0) {
                shell->buffer.buffer_pos -= 1;
                draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
                shell->cursor.pos_x -= 8;
                draw_char(shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.nth_command][shell->buffer.buffer_pos], 0x000000, false, &OwOSFont_8x16);
                shell->buffer.buffer[shell->buffer.nth_command][shell->buffer.buffer_pos] = 0;
            }
        } else {
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
            push_char(&shell->buffer, c);
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y, shell->buffer.buffer[shell->buffer.nth_command][shell->buffer.buffer_pos - 1], 0xFFFFFF, false, &OwOSFont_8x16);
            move_cursor(&shell->cursor, 8);
        }
    }
}

void update_cursor(struct Shell* shell) {
    if (shell->cursor.pos_y > SCREEN_HEIGHT - 52) {
        clear_screen(shell);
    }
    if (ticks - shell->cursor.last_toggle >= 250) {
        shell->cursor.last_toggle = ticks;
        shell->cursor.visible = !shell->cursor.visible;

        if (shell->cursor.visible) {
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0xFFFFFF, false, &OwOSFont_8x16);
        } else {
            draw_char(shell->cursor.pos_x, shell->cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
        }
    }
}

char time[64];

void update_shell(struct Shell* shell) {
    if (ticks % 100 == 0) {
        draw_text(SCREEN_WIDTH - strlen(time) * 8 - 5, SCREEN_HEIGHT - 18, time, 0x101010, false, &OwOSFont_8x16);
        memset(time, 0, sizeof time);
        read_rtc();
        format(time, "%d:%d:%d | %d/%d/%d", hour, minute, second, day, month, year);
        draw_text(SCREEN_WIDTH - strlen(time) * 8 - 5, SCREEN_HEIGHT - 18, time, 0xAAAAAA, false, &OwOSFont_8x16);
    };
    update_cursor(shell);
    update_buffer(shell);
}

