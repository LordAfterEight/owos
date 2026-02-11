#include <stddef.h>
#include <stdint.h>
#include "std.h"

void *owos_memcpy(void *restrict dest, const void *restrict src, size_t n) {
    outb(0x3F8, 'M');
    outb(0x3F8, 'C');
    uint8_t *restrict pdest = (uint8_t *restrict)dest;
    const uint8_t *restrict psrc = (const uint8_t *restrict)src;
    for (size_t i = 0; i < n; i++) {
        pdest[i] = psrc[i];
        if (i % 100 == 0) outb(0x3F8, '.');
    }
    outb(0x3F8, 'D');
    outb(0x3F8, '\n');
    outb(0x3F8, '\r');
    return dest;
}

void *owos_memset(void *s, int c, size_t n) {
    outb(0x3F8, 'M');
    outb(0x3F8, 'S');
    uint8_t *p = (uint8_t *)s;
    for (size_t i = 0; i < n; i++) {
        p[i] = (uint8_t)c;
        if (i % 100 == 0) outb(0x3F8, '.');
    }
    outb(0x3F8, 'D');
    outb(0x3F8, '\n');
    outb(0x3F8, '\r');
    return s;
}


void *owos_memmove(void *dest, const void *src, size_t n) {
    outb(0x3F8, 'M');
    outb(0x3F8, 'M');
    uint8_t *pdest = (uint8_t *)dest;
    const uint8_t *psrc = (const uint8_t *)src;
    if (src > dest) {
        for (size_t i = 0; i < n; i++) {
            pdest[i] = psrc[i];
            if (i % 100 == 0) outb(0x3F8, '.');
        }
    } else if (src < dest) {
        for (size_t i = n; i > 0; i--) {
            pdest[i-1] = psrc[i-1];
            if (i % 100 == 0) outb(0x3F8, '.');
        }
    }
    outb(0x3F8, 'D');
    outb(0x3F8, '\n');
    outb(0x3F8, '\r');
    return dest;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    outb(0x3F8, 'M');
    outb(0x3F8, '=');
    const uint8_t *p1 = (const uint8_t *)s1;
    const uint8_t *p2 = (const uint8_t *)s2;
    for (size_t i = 0; i < n; i++) {
        if (p1[i] != p2[i]) {
            return p1[i] < p2[i] ? -1 : 1;
        }
        if (i % 100 == 0) outb(0x3F8, '.');
    }
    outb(0x3F8, 'D');
    outb(0x3F8, '\n');
    outb(0x3F8, '\r');
    return 0;
}

