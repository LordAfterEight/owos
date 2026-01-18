#ifndef TIMER_H
#define TIMER_H

#pragma once
#include <stdint.h>
#include "shell/shell_definitions.h"

struct Shell;

#define PIT_CHANNEL0 0x40
#define PIT_CMD      0x43
#define PIT_FREQ     1193182

extern volatile unsigned long ticks;

void pit_init(struct Shell* shell, uint32_t frequency);
void timer_callback(void *frame);

#endif
