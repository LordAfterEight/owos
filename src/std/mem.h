#include <stddef.h>
#include <stdint.h>

typedef uint64_t size_t;

void *owos_memcpy(void *restrict dest, const void *restrict src, size_t n);
void *owos_memset(void *se, int c, size_t n);
void *owos_memmove(void *dest, const void *src, size_t n);
int owos_memcmp(const void *s1, const void *s2, size_t n);
