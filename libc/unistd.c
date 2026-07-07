#include <unistd.h>
#include <owos/api.h>
#include <stdarg.h>

ssize_t read(int fd, void *buf, size_t count) {
    if (!owos_api || !owos_api->read) {
        return -1;
    }
    return (ssize_t)owos_api->read(fd, buf, (unsigned long)count);
}

ssize_t write(int fd, const void *buf, size_t count) {
    if (!owos_api || !owos_api->write) {
        return -1;
    }
    return (ssize_t)owos_api->write(fd, buf, (unsigned long)count);
}

int open(const char *path, int flags, ...) {
    (void)flags;
    if (!owos_api || !owos_api->open) {
        return -1;
    }
    return owos_api->open(path, flags);
}

int close(int fd) {
    if (!owos_api || !owos_api->close) {
        return -1;
    }
    return owos_api->close(fd);
}

long lseek(int fd, long offset, int whence) {
    if (!owos_api || !owos_api->lseek) {
        return -1;
    }
    return owos_api->lseek(fd, offset, whence);
}

void _exit(int status) {
    if (owos_api && owos_api->exit) {
        owos_api->exit(status);
    }
    for (;;) {
        __asm__ volatile("hlt");
    }
}