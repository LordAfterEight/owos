#include "timer.h"
#include "std/std.h"
#include "rendering.h"
#include "idt.h"
#include "fonts/OwOSFont_8x16.h"

volatile uint32_t ticks = 0;

void pit_init(uint32_t frequency) {
    uint16_t divisor = (uint16_t)(PIT_FREQ / frequency);
    outb(PIT_CMD, 0x36);          // channel 0, lobyte/hibyte, mode 3
    outb(PIT_CHANNEL0, divisor & 0xFF);
    outb(PIT_CHANNEL0, divisor >> 8);
    char buf[64];
}
