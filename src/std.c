#include "rendering.h"
#include "stdio.h"

size_t strlen(const char* s) {
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

void panic(uint32_t* fb_ptr, const char message[]) {
    for (int y = 0; y < SCREEN_HEIGHT; y++) {
        for (int x = 0; x < SCREEN_WIDTH; x++) {
            blit_pixel(fb_ptr, x, y, 0x770000);
        }
    }
    draw_text(fb_ptr, (SCREEN_WIDTH - strlen(" KERNEL PANIC ") * 8) / 2, SCREEN_HEIGHT / 3, " KERNEL_PANIC ", 0xFFFFFF, true);
    draw_text(fb_ptr, (SCREEN_WIDTH - strlen(message) * 8) / 2, SCREEN_HEIGHT / 3 + 10, message, 0xFFFFFF, false);
    while (1) {
        asm ("hlt");
    }
}

bool strcmp(const char* a, const char* b) {
    while (*a && *b) {
        if (*a != *b) return false;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

void outb(uint16_t port, uint8_t val) {
    asm volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

uint8_t inb(uint16_t port) {
    uint8_t ret;
    asm volatile ("inb %1, %0" : "=a"(ret) : "Nd"(port));
    return ret;
}
