#include <stdbool.h>
#include <stdint.h>

uint32_t strlen(const char* s) {
    const char *p = s;
    while (*p)
        p++;
    return (uint32_t)(p - s);
}

bool strcmp(const char* a, const char* b) {
    while (*a && *b) {
        if (*a != *b) return false;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

