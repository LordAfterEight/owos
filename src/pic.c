#include "pic.h"
#include "std/std.h" // inb/outb

static inline void io_wait(void) {
    outb(0x80, 0);
}

void pic_remap(void) {
    uint8_t a1 = inb(PIC1_DATA);
    uint8_t a2 = inb(PIC2_DATA);

    outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4); io_wait();
    outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4); io_wait();

    outb(PIC1_DATA, 0x20); io_wait();
    outb(PIC2_DATA, 0x28); io_wait();

    outb(PIC1_DATA, 4); io_wait();
    outb(PIC2_DATA, 2); io_wait();

    outb(PIC1_DATA, ICW4_8086); io_wait();
    outb(PIC2_DATA, ICW4_8086); io_wait();

    outb(PIC1_DATA, a1); io_wait();
    outb(PIC2_DATA, a2); io_wait();
}

void pic_eoi(uint8_t irq) {
    if(irq >= 8) outb(0xA0, 0x20);
    outb(0x20, 0x20);

}
