#include "rendering.h"
#include "fonts/OwOSFont_8x16.h"
#include "timer.h"
#include "sound/pcspeaker.h"
#include <stdarg.h>
#include "string.h"

void panic(const char message[]) {
    //beep(500, 25);
    for (int y = 0; y < SCREEN_HEIGHT-1; y++) {
        for (int x = 0; x < SCREEN_WIDTH-1; x++) {
            blit_pixel(x, y, 0x550000);
        }
    }
    draw_text((SCREEN_WIDTH - strlen(" KERNEL PANIC ") * 8) / 2, SCREEN_HEIGHT / 3, " KERNEL PANIC ", 0xFFFFFF, true, &OwOSFont_8x16);
    char buf[32];
    format(buf, "Reason: %s", message);
    draw_text((SCREEN_WIDTH - strlen(buf) * 8) / 2, SCREEN_HEIGHT / 3 + 16, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    for (int i = 10; i > 0; i--) {
        format(buf, "Trying to recover in: %ds", i);
        draw_text((SCREEN_WIDTH - strlen(buf) * 8) / 2, SCREEN_HEIGHT / 3 + 64, buf, 0xFFFFFF, false, &OwOSFont_8x16);
        msleep(1000);
        draw_text((SCREEN_WIDTH - strlen(buf) * 8) / 2, SCREEN_HEIGHT / 3 + 64, buf, 0x550000, false, &OwOSFont_8x16);
    }
    for (int y = 0; y < SCREEN_HEIGHT; y++) {
        for (int x = 0; x < SCREEN_WIDTH; x++) {
            blit_pixel(x, y, 0x000000);
        }
    }
}

uint8_t inb(uint16_t port) {
    uint8_t ret;
    asm volatile ("inb %1, %0" : "=a"(ret) : "Nd"(port));
    return ret;
}

void outb(uint16_t port, uint8_t val) {
    asm volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

void outw(uint16_t port, uint16_t val) {
    asm volatile ("outw %0, %1" : : "a"(val), "Nd"(port));
}

char* utoa_limited(char* buf, size_t space, unsigned value, int base) {
    if (space == 0) return buf;

    char temp[11];
    char* t = temp + sizeof(temp) - 1;
    *t = '\0';
    do {
        unsigned digit = value % base;
        value /= base;
        if (t > temp) *--t = (digit < 10) ? (digit + '0') : (digit - 10 + 'a');
    } while (value && t > temp);
    while (*t && space > 1) {
        *buf++ = *t++;
        space--;
    }
    return buf;
}

char* utoa_internal(char* buf, unsigned int value, int base) {
    char temp[11];
    char* t = temp + 10;
    *t = '\0';
    do {
        unsigned int digit = value % base;
        value /= base;
        *--t = (digit < 10) ? (digit + '0') : (digit - 10 + 'a');
    } while (value);
    while (*t)
        *buf++ = *t++;
    return buf;
}

char* utoa_upper_internal(char* buf, unsigned int value, int base) {
    char temp[11];
    char* t = temp + 10;
    *t = '\0';
    do {
        unsigned int digit = value % base;
        value /= base;
        *--t = (digit < 10) ? (digit + '0') : (digit - 10 + 'A');
    } while (value);
    while (*t)
        *buf++ = *t++;
    return buf;
}

void format(char* buf, const char* fmt, ...) {
    va_list va;
    va_start(va, fmt);
    char* p = buf;
    int width = 0;
    while (*fmt)
    {
        if (*fmt == '%')
        {
            fmt++;
            width = 0;
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + (*fmt++ - '0');
            switch (*fmt++)
            {
                case 'c':   *p++ = (char)va_arg(va, int); break;
                case 's':
                {
                    const char* s = va_arg(va, const char*);
                    while (*s) *p++ = *s++;
                    break;
                }
                case 'd':
                case 'i':
                {
                    int val = va_arg(va, int);
                    if (val < 0) { *p++ = '-'; val = -val; }
                    p = utoa_internal(p, val, 10);
                    break;
                }
                case 'u':   p = utoa_internal(p, va_arg(va, unsigned), 10); break;
                case 'x':   p = utoa_internal(p, va_arg(va, unsigned), 16); break;
                case 'X':   p = utoa_upper_internal(p, va_arg(va, unsigned), 16); break;
                case 'p':
                    *p++ = '0';
                    *p++ = 'x';
                    p = utoa_internal(p, (uintptr_t)va_arg(va, void*), 16);
                    break;
                case '%':   *p++ = '%'; break;
                default:
                    *p++ = '%';
                    p[-1] = fmt[-1];
                    break;
            }
        }
        else
        {
            *p++ = *fmt++;
        }
    }
    *p = '\0';
    va_end(va);
}

void msleep(uint64_t ms) {
    if (ms == 0) return;

    uint64_t start = ticks;
    uint64_t target = start + ms;

    while (ticks < target) {
        asm volatile("sti; hlt;");
    }
}
