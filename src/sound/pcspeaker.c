#include "pcspeaker.h"
#include "std/std.h"

void play_sound(uint32_t frequency) {
    uint32_t Div;
    uint8_t tmp;

    Div = 1193180 / frequency;
    outb(0x43, 0xb6);
    outb(0x42, (uint8_t) (Div) );
    outb(0x42, (uint8_t) (Div >> 8));

    tmp = inb(0x61);
    if (tmp != (tmp | 3)) {
        outb(0x61, tmp | 3);
    }
}

void nosound() {
    uint8_t tmp = inb(0x61) & 0xFC;
    outb(0x61, tmp);
}

void beep(uint32_t frequency, uint32_t duration) {
    play_sound(frequency);
    msleep(duration);
    nosound();
}
