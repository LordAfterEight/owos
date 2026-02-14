#ifndef STD_H
#define STD_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

static char* KERNEL_VERSION = "0.3.3";
static char* KERNEL_NAME = "OwOS";
static char* OS_MODEL = "Volatile";

extern volatile uint8_t panic_count;

void panic(const char message[]);
uint8_t inb(uint16_t port);
void outb(uint16_t port, uint8_t val);
void outw(uint16_t port, uint16_t val);
char* utoa_limited(char* buf, size_t space, unsigned value, int base);
char* utoa_internal(char* buf, unsigned int value, int base);
char* utoa_upper_internal(char* buf, unsigned int value, int base);
void format(char* buf, const char* fmt, ...);
void msleep(uint64_t ms);

typedef struct {
    void* T[];
} Vec;

#endif
