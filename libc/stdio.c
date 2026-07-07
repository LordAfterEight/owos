#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>

struct FILE {
    int fd;
    int err;
};

FILE *fdopen(int fd, const char *mode) {
    (void)mode;
    FILE *f = (FILE *)malloc(sizeof(FILE));
    if (!f) {
        return 0;
    }
    f->fd = fd;
    f->err = 0;
    return f;
}

static FILE stdin_file = { 0, 0 };
static FILE stdout_file = { 1, 0 };
static FILE stderr_file = { 2, 0 };

FILE *stdin = &stdin_file;
FILE *stdout = &stdout_file;
FILE *stderr = &stderr_file;

static int stream_fd(FILE *stream) {
    return stream ? stream->fd : -1;
}

static int format_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);

static int write_fd(int fd, const char *s, size_t n) {
    ssize_t w = write(fd, s, n);
    return w < 0 ? -1 : (int)w;
}

int fputc(int c, FILE *stream) {
    unsigned char ch = (unsigned char)c;
    return write_fd(stream_fd(stream), (const char *)&ch, 1) == 1 ? c : -1;
}

int fputs(const char *s, FILE *stream) {
    return write_fd(stream_fd(stream), s, strlen(s));
}

int puts(const char *s) {
    if (fputs(s, stdout) < 0) {
        return -1;
    }
    return fputc('\n', stdout);
}

int fflush(FILE *stream) {
    (void)stream;
    return 0;
}

static int out_char(int c, void *ctx) {
    struct {
        char *buf;
        size_t size;
        size_t pos;
        int fd;
        int use_fd;
    } *o = ctx;
    if (o->use_fd) {
        unsigned char ch = (unsigned char)c;
        return write_fd(o->fd, (const char *)&ch, 1) == 1 ? 0 : -1;
    }
    if (o->pos + 1 < o->size) {
        o->buf[o->pos++] = (char)c;
    }
    return 0;
}

static int format_core(const char *fmt, va_list ap, void *ctx,
                       int (*emit)(int, void *)) {
    while (*fmt) {
        if (*fmt != '%') {
            if (emit(*fmt++, ctx) < 0) {
                return -1;
            }
            continue;
        }
        fmt++;
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        (void)width;
        if (*fmt == 'l') {
            fmt++;
        }
        switch (*fmt++) {
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) {
                s = "(null)";
            }
            while (*s) {
                if (emit(*s++, ctx) < 0) {
                    return -1;
                }
            }
            break;
        }
        case 'c': {
            int c = va_arg(ap, int);
            if (emit(c, ctx) < 0) {
                return -1;
            }
            break;
        }
        case 'd':
        case 'i': {
            int v = va_arg(ap, int);
            char tmp[16];
            unsigned int x;
            int i = 0;
            if (v < 0) {
                if (emit('-', ctx) < 0) {
                    return -1;
                }
                x = (unsigned int)(-(v + 1)) + 1u;
            } else {
                x = (unsigned int)v;
            }
            do {
                tmp[i++] = (char)('0' + (x % 10));
                x /= 10;
            } while (x);
            while (i > 0) {
                if (emit(tmp[--i], ctx) < 0) {
                    return -1;
                }
            }
            break;
        }
        case 'u': {
            unsigned int v = va_arg(ap, unsigned int);
            char tmp[16];
            int i = 0;
            do {
                tmp[i++] = (char)('0' + (v % 10));
                v /= 10;
            } while (v);
            if (i == 0) {
                tmp[i++] = '0';
            }
            while (i > 0) {
                if (emit(tmp[--i], ctx) < 0) {
                    return -1;
                }
            }
            break;
        }
        case 'p':
        case 'x': {
            unsigned long v = (unsigned long)va_arg(ap, unsigned long);
            const char *hex = "0123456789abcdef";
            if (*fmt == 'p' || fmt[-1] == 'p') {
                if (emit('0', ctx) < 0 || emit('x', ctx) < 0) {
                    return -1;
                }
            }
            char tmp[20];
            int i = 0;
            do {
                tmp[i++] = hex[v & 0xf];
                v >>= 4;
            } while (v);
            if (i == 0) {
                tmp[i++] = '0';
            }
            while (i > 0) {
                if (emit(tmp[--i], ctx) < 0) {
                    return -1;
                }
            }
            break;
        }
        case '%':
            if (emit('%', ctx) < 0) {
                return -1;
            }
            break;
        default:
            if (emit('%', ctx) < 0) {
                return -1;
            }
            break;
        }
    }
    return 0;
}

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    struct {
        char *buf;
        size_t size;
        size_t pos;
        int fd;
        int use_fd;
    } ctx = { 0, 0, 0, 1, 1 };
    int rc = format_core(fmt, ap, &ctx, out_char);
    va_end(ap);
    return rc < 0 ? -1 : (int)ctx.pos;
}

int fprintf(FILE *stream, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    struct {
        char *buf;
        size_t size;
        size_t pos;
        int fd;
        int use_fd;
    } ctx = { 0, 0, 0, stream_fd(stream), 1 };
    int rc = format_core(fmt, ap, &ctx, out_char);
    va_end(ap);
    return rc < 0 ? -1 : (int)ctx.pos;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int rc = format_vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return rc;
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    return format_vsnprintf(buf, size, fmt, ap);
}

int sprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int rc = format_vsnprintf(buf, 4096, fmt, ap);
    va_end(ap);
    return rc;
}

int sscanf(const char *str, const char *fmt, ...) {
    (void)str;
    (void)fmt;
    return 0;
}

int fseek(FILE *stream, long offset, int whence) {
    if (!stream) {
        return -1;
    }
    long pos = lseek(stream->fd, offset, whence);
    return pos < 0 ? -1 : 0;
}

long ftell(FILE *stream) {
    if (!stream) {
        return -1;
    }
    return lseek(stream->fd, 0, SEEK_CUR);
}

static int format_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    struct {
        char *buf;
        size_t size;
        size_t pos;
        int fd;
        int use_fd;
    } ctx = { buf, size, 0, 0, 0 };
    int rc = format_core(fmt, ap, &ctx, out_char);
    if (size > 0) {
        size_t n = ctx.pos < size - 1 ? ctx.pos : size - 1;
        buf[n] = '\0';
    }
    return rc < 0 ? -1 : (int)ctx.pos;
}

static int mode_to_flags(const char *mode) {
    if (!mode || !mode[0]) {
        return -1;
    }
    if (mode[0] == 'r') {
        return O_RDONLY;
    }
    if (mode[0] == 'w') {
        return O_WRONLY | O_CREAT | O_TRUNC;
    }
    if (mode[0] == 'a') {
        return O_WRONLY | O_CREAT | O_APPEND;
    }
    return -1;
}

FILE *fopen(const char *path, const char *mode) {
    int flags = mode_to_flags(mode);
    if (flags < 0) {
        return 0;
    }
    int fd = open(path, flags);
    if (fd < 0) {
        return 0;
    }
    FILE *f = (FILE *)malloc(sizeof(FILE));
    if (!f) {
        close(fd);
        return 0;
    }
    f->fd = fd;
    f->err = 0;
    return f;
}

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream) {
    if (!stream || !ptr || size == 0) {
        return 0;
    }
    ssize_t n = read(stream->fd, ptr, size * nmemb);
    if (n < 0) {
        stream->err = 1;
        return 0;
    }
    return (size_t)n / size;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) {
    if (!stream || !ptr || size == 0) {
        return 0;
    }
    ssize_t n = write(stream->fd, ptr, size * nmemb);
    if (n < 0) {
        stream->err = 1;
        return 0;
    }
    return (size_t)n / size;
}

int fclose(FILE *stream) {
    if (!stream || stream == stdin || stream == stdout || stream == stderr) {
        return 0;
    }
    int rc = close(stream->fd);
    free(stream);
    return rc;
}