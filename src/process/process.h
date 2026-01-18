#ifndef PROCESS
#define PROCESS

#include <stdint.h>

const struct Process {
    char* name;
    uint8_t id;
    int (*run)();
};

#endif
