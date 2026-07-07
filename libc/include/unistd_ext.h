#ifndef UNISTD_EXT_H
#define UNISTD_EXT_H

#include <stddef.h>

int remove(const char *path);
int execvp(const char *path, char *const argv[]);
int rename(const char *oldpath, const char *newpath);
char *getcwd(char *buf, size_t size);
int chdir(const char *path);
int access(const char *path, int mode);
int isatty(int fd);
long sysconf(int name);

#endif