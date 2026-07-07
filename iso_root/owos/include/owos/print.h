#ifndef OWOS_PRINT_H
#define OWOS_PRINT_H

#include <stdarg.h>

/* Formatted stdout output (implemented in libc). */
int print_fmt(const char *fmt, ...);
int println_fmt(const char *fmt, ...);

/* Ergonomic macros — plain strings and printf-style formats both work. */
#define print(...) print_fmt(__VA_ARGS__)
#define println(...) println_fmt(__VA_ARGS__)

#endif