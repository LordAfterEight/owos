#ifndef SYS_MMAN_H
#define SYS_MMAN_H

#include <stddef.h>

#define PROT_READ  1
#define PROT_WRITE 2
#define PROT_EXEC  4
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20

void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int munmap(void *addr, size_t length);
int mprotect(void *addr, size_t len, int prot);

#endif