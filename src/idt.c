#include <stdint.h>
#include "std/std.h"
#include "shell/shell_definitions.h"
#include "idt.h"
#include "fonts/OwOSFont_8x16.h"
#include "timer.h"

struct IDTEntry idt[256] __attribute__((aligned(16)));

struct IDTPointer idt_ptr __attribute__((aligned(16)));

const char* panic_reason = {0};

void set_idt_entry(int vector, interrupt_handler_t handler, uint8_t ist, uint8_t type_attr) {
    uint64_t addr = (uint64_t)handler;

    idt[vector].offset_low  = addr & 0xFFFF;
    idt[vector].offset_mid  = (addr >> 16) & 0xFFFF;
    idt[vector].offset_high = (addr >> 32) & 0xFFFFFFFF;

    idt[vector].selector    = 0x08;
    idt[vector].ist         = ist;
    idt[vector].type_attr   = type_attr;
    idt[vector].zero        = 0;
}

bool check_idt_entry(int vector, interrupt_handler_t handler, uint8_t ist, uint8_t type_attr) {
    uint64_t addr = (uint64_t)handler;

    if (
        (idt[vector].offset_low  == (addr & 0xFFFF)) &&
        (idt[vector].offset_mid  == ((addr >> 16) & 0xFFFF)) &&
        (idt[vector].offset_high == ((addr >> 32) & 0xFFFFFFFF)) &&
        idt[vector].selector    == 0x08 &&
        idt[vector].ist         == ist &&
        idt[vector].type_attr   == type_attr &&
        idt[vector].zero        == 0
    ) {
        return true;
    }
    return false;

}

void idt_init(void) {
    set_idt_entry(32, timer_handler_asm, 0, 0x8E);
    set_idt_entry(8, double_fault_handler, 0, 0x8E);
    set_idt_entry(14, page_fault_handler, 0, 0x8E);

    idt_ptr.limit = sizeof(idt) - 1;
    idt_ptr.base  = (uint64_t)&idt;

    asm volatile("lidt %0" : : "m"(idt_ptr) : "memory");
}

__attribute__((interrupt))
void default_handler(struct InterruptFrame* frame) {
    (void)frame;
    for(;;) asm volatile("cli; hlt");
}

__attribute__((interrupt))
void default_handler_err(struct InterruptFrame* frame, uint64_t error_code) {
    (void)frame;
    (void)error_code;
    for(;;) asm volatile("cli; hlt");
}

__attribute__((interrupt))
void page_fault_handler(struct InterruptFrame* frame, uint64_t error_code) {
    (void)frame;
    (void)error_code;
    panic_reason = "PAGE FAULT";
    asm volatile (
        ".global panic_handler_c; call panic_handler_c"
    );
}

__attribute__((interrupt))
void double_fault_handler(struct InterruptFrame* frame, uint64_t error_code) {
    (void)frame;
    (void)error_code;
    panic_reason = "DOUBLE FAULT";
    asm volatile (
        ".global panic_handler_c; call panic_handler_c"
    );
}

void panic_handler_c(struct InterruptFrame* frame) {
    char buf[64];
    panic(panic_reason);
    if (panic_count >= 2) {
        draw_text(1, 30, "Please restart your computer", 0xFF7777, false, &OwOSFont_8x16);
        for (;;) asm volatile ("hlt");
    }
    format(buf, "Instruction Pointer: 0x%x", frame->ip);
    draw_text(1, 1, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    format(buf, "Stack Pointer: 0x%x", frame->sp);
    draw_text(1, 17, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    msleep(5000);
}
