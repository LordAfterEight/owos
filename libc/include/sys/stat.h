#ifndef SYS_STAT_H
#define SYS_STAT_H

struct stat {
    long st_size;
};

int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);

#endif