#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <owos/api.h>

#define OWOS_ALLOC_OVERHEAD 16

static void *alloc_raw(size_t user_size, size_t *out_user_size) {
    size_t total = OWOS_ALLOC_OVERHEAD + user_size;
    void *raw;
    if (!owos_api || !owos_api->alloc) {
        return 0;
    }
    raw = owos_api->alloc((unsigned long)total);
    if (!raw) {
        return 0;
    }
    ((size_t *)raw)[0] = user_size;
    if (out_user_size) {
        *out_user_size = user_size;
    }
    return (char *)raw + OWOS_ALLOC_OVERHEAD;
}

static size_t alloc_user_size(const void *ptr) {
    return ((const size_t *)((const char *)ptr - OWOS_ALLOC_OVERHEAD))[0];
}

void *malloc(size_t size) {
    return alloc_raw(size, 0);
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *p = alloc_raw(total, 0);
    if (!p) {
        return 0;
    }
    memset(p, 0, total);
    return p;
}

void *realloc(void *ptr, size_t size) {
    void *n;
    size_t old;
    size_t copy;
    if (!ptr) {
        return malloc(size);
    }
    if (size == 0) {
        free(ptr);
        return 0;
    }
    old = alloc_user_size(ptr);
    n = malloc(size);
    if (!n) {
        return 0;
    }
    copy = old < size ? old : size;
    if (copy > 0) {
        memcpy(n, ptr, copy);
    }
    return n;
}

void free(void *ptr) {
    (void)ptr;
}

long strtol(const char *s, char **endptr, int base) {
    (void)base;
    long n = atoi(s);
    if (endptr) {
        *endptr = (char *)s;
    }
    return n;
}

unsigned long strtoul(const char *s, char **endptr, int base) {
    return (unsigned long)strtol(s, endptr, base);
}

unsigned long long strtoull(const char *s, char **endptr, int base) {
    return (unsigned long long)strtoul(s, endptr, base);
}

char *getenv(const char *name) {
    (void)name;
    return 0;
}

int atoi(const char *s) {
    int n = 0;
    int neg = 0;
    if (!s) {
        return 0;
    }
    while (*s == ' ' || *s == '\t') {
        s++;
    }
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    while (*s >= '0' && *s <= '9') {
        n = n * 10 + (*s - '0');
        s++;
    }
    return neg ? -n : n;
}

void abort(void) {
    _exit(134);
}

void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *)) {
    char *bytes = (char *)base;
    char *tmp = (char *)malloc(size);
    if (!tmp) {
        return;
    }
    for (size_t i = 1; i < nmemb; i++) {
        char *key = bytes + i * size;
        size_t j = i;
        while (j > 0 && compar(bytes + (j - 1) * size, key) > 0) {
            memcpy(tmp, bytes + (j - 1) * size, size);
            memcpy(bytes + (j - 1) * size, bytes + j * size, size);
            memcpy(bytes + j * size, tmp, size);
            j--;
        }
    }
    free(tmp);
}

double strtod(const char *nptr, char **endptr) {
    double sign = 1.0;
    double val = 0.0;
    const char *s = nptr;
    if (*s == '-') {
        sign = -1.0;
        s++;
    } else if (*s == '+') {
        s++;
    }
    while (*s >= '0' && *s <= '9') {
        val = val * 10.0 + (*s - '0');
        s++;
    }
    if (*s == '.') {
        s++;
        double div = 10.0;
        while (*s >= '0' && *s <= '9') {
            val += (*s - '0') / div;
            div *= 10.0;
            s++;
        }
    }
    if (endptr) {
        *endptr = (char *)s;
    }
    return sign * val;
}

void exit(int status) {
    _exit(status);
}