#include <stdbool.h>
#include <stdint.h>

extern volatile uint8_t panic_count;

uint32_t strlen(const char s[]);
bool strcmp(const char* a, const char* b);
