#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef SEEK_CUR
#define SEEK_CUR 1
#endif
#ifndef SEEK_END
#define SEEK_END 2
#endif
#ifndef SEEK_SET
#define SEEK_SET 0
#endif

int remove(const char *path) {
    (void)path;
    return 0;
}

int rename(const char *oldpath, const char *newpath) {
    (void)oldpath;
    (void)newpath;
    return -1;
}

char *getcwd(char *buf, size_t size) {
    if (!buf || size == 0) {
        return 0;
    }
    strncpy(buf, ".", size);
    return buf;
}

int chdir(const char *path) {
    (void)path;
    return 0;
}

int access(const char *path, int mode) {
    (void)mode;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    close(fd);
    return 0;
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset) {
    (void)addr;
    (void)prot;
    (void)flags;
    (void)fd;
    (void)offset;
    void *p = malloc(length);
    return p;
}

int munmap(void *addr, size_t length) {
    (void)addr;
    (void)length;
    return 0;
}

#include <sys/stat.h>

static int fill_stat_size(int fd, struct stat *buf) {
    long pos;
    long size;
    if (!buf) {
        return -1;
    }
    memset(buf, 0, sizeof(*buf));
    pos = lseek(fd, 0, SEEK_CUR);
    if (pos < 0) {
        return -1;
    }
    size = lseek(fd, 0, SEEK_END);
    if (size < 0) {
        return -1;
    }
    if (lseek(fd, pos, SEEK_SET) < 0) {
        return -1;
    }
    buf->st_size = size;
    return 0;
}

int stat(const char *path, struct stat *buf) {
    int fd;
    int rc;
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    rc = fill_stat_size(fd, buf);
    close(fd);
    return rc;
}

int fstat(int fd, struct stat *buf) {
    return fill_stat_size(fd, buf);
}

int isatty(int fd) {
    return fd >= 0 && fd <= 2;
}

long sysconf(int name) {
    (void)name;
    return 4096;
}

#include <sys/time.h>

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    if (tv) {
        tv->tv_sec = 0;
        tv->tv_usec = 0;
    }
    return 0;
}

#include <signal.h>

time_t time(time_t *t) {
    if (t) {
        *t = 0;
    }
    return 0;
}

struct tm *localtime(const time_t *t) {
    static struct tm tm;
    (void)t;
    tm.tm_sec = 0;
    tm.tm_min = 0;
    tm.tm_hour = 0;
    tm.tm_mday = 1;
    tm.tm_mon = 0;
    tm.tm_year = 70;
    return &tm;
}

int sigemptyset(unsigned long *set) {
    if (set) {
        *set = 0;
    }
    return 0;
}

int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact) {
    (void)signum;
    (void)act;
    (void)oldact;
    return 0;
}

int unlink(const char *path) {
    return remove(path);
}

int execvp(const char *path, char *const argv[]) {
    (void)path;
    (void)argv;
    return -1;
}

float strtof(const char *nptr, char **endptr) {
    return (float)strtol(nptr, endptr, 10);
}

long double strtold(const char *nptr, char **endptr) {
    return (long double)strtol(nptr, endptr, 10);
}

int mprotect(void *addr, size_t len, int prot) {
    (void)addr;
    (void)len;
    (void)prot;
    return 0;
}

int vfprintf(FILE *stream, const char *fmt, va_list ap) {
    char buf[512];
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    if (n <= 0) {
        return n;
    }
    return fputs(buf, stream);
}