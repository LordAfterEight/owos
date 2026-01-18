#include "timer.h"
#include "std.h"
#include "rendering.h"
#include "shell/shell_definitions.h"
#include "idt.h"
#include "fonts/OwOSFont_8x16.h"

volatile unsigned long ticks = 0;

void pit_init(struct Shell* shell, uint32_t frequency) {
    uint16_t divisor = (uint16_t)(PIT_FREQ / frequency);
    outb(PIT_CMD, 0x36);          // channel 0, lobyte/hibyte, mode 3
    outb(PIT_CHANNEL0, divisor & 0xFF);
    outb(PIT_CHANNEL0, divisor >> 8);
    char buf[64];
    format(buf, "Initialized Programmable Interval Timer with frequency %dHz", frequency);
    shell_print("[Kernel:PIT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println(buf, 0xFFFFFF, false, &OwOSFont_8x16);
}

__attribute__((used, interrupt))
void timer_callback(void *frame) {
    ticks++;
    outb(0x20, 0x20);
}
