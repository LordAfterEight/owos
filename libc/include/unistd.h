#ifndef UNISTD_H
#define UNISTD_H

#include <stddef.h>

#include <fcntl.h>

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

typedef long ssize_t;

ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int open(const char *path, int flags, ...);
int close(int fd);
long lseek(int fd, long offset, int whence);
int remove(const char *path);
int unlink(const char *path);
int execvp(const char *path, char *const argv[]);
char *getcwd(char *buf, size_t size);
void _exit(int status);

#endif