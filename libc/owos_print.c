#include <owos/print.h>
#include <stdio.h>
#include <stdarg.h>

int print_fmt(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int rc = vfprintf(stdout, fmt, ap);
    va_end(ap);
    return rc;
}

int println_fmt(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int rc = vfprintf(stdout, fmt, ap);
    va_end(ap);
    if (rc < 0) {
        return -1;
    }
    return fputc('\n', stdout) == '\n' ? rc + 1 : -1;
}