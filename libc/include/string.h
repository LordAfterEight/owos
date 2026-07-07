#ifndef STRING_H
#define STRING_H

#include <stddef.h>

int memcmp(const void *a, const void *b, size_t n);
char *strcat(char *dst, const char *src);
char *strstr(const char *haystack, const char *needle);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strcpy(char *dst, const char *src);
char *strncpy(char *dst, const char *src, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
size_t strlen(const char *s);
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

#endif