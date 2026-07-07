#ifndef TIME_H
#define TIME_H

typedef long time_t;

struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
};

time_t time(time_t *t);
struct tm *localtime(const time_t *t);

#endif