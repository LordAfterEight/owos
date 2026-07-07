#ifndef OWOS_API_H
#define OWOS_API_H

#include <stddef.h>

typedef long (*owos_write_fn)(int fd, const void *buf, unsigned long count);
typedef void (*owos_exit_fn)(int status);
typedef void *(*owos_alloc_fn)(unsigned long size);
typedef int (*owos_open_fn)(const char *path, int flags);
typedef long (*owos_read_fn)(int fd, void *buf, unsigned long count);
typedef int (*owos_close_fn)(int fd);
typedef long (*owos_lseek_fn)(int fd, long offset, int whence);

typedef struct OwosApi {
    owos_write_fn write;
    owos_exit_fn exit;
    owos_alloc_fn alloc;
    owos_open_fn open;
    owos_read_fn read;
    owos_close_fn close;
    owos_lseek_fn lseek;
} OwosApi;

extern const OwosApi *owos_api;

#endif