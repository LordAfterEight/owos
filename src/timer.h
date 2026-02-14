#ifndef TIMER_H
#define TIMER_H

#pragma once
#include <stdint.h>
#include "idt.h"

struct Shell;

#define PIT_CHANNEL0 0x40
#define PIT_CMD      0x43
#define PIT_FREQ     1193182

extern volatile uint32_t ticks;

void pit_init(uint32_t frequency);

__attribute__((interrupt))
void timer_callback(struct InterruptFrame *frame);

#endif
