#ifndef STDLIB_H
#define STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
void exit(int status);
int atoi(const char *s);
long strtol(const char *s, char **endptr, int base);
unsigned long strtoul(const char *s, char **endptr, int base);
unsigned long long strtoull(const char *s, char **endptr, int base);
char *getenv(const char *name);
void abort(void);
void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *));
double strtod(const char *nptr, char **endptr);

#endif