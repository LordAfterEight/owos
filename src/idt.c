#include <stdint.h>
#include "std/std.h"
#include "idt.h"

struct IDTEntry idt[256] __attribute__((aligned(16)));

struct IDTPointer idt_ptr __attribute__((aligned(16)));

const char* panic_reason = {0};

extern void syscall_80(void);

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
    set_idt_entry(6, invalid_opcode_handler, 0, 0x8E);
    set_idt_entry(8, double_fault_handler, 1, 0x8E);
    set_idt_entry(13, general_protection_handler, 0, 0x8E);
    set_idt_entry(14, page_fault_handler, 0, 0x8E);
    set_idt_entry_stub(0x80, syscall_80, 0, 0xEE);

    idt_ptr.limit = sizeof(idt) - 1;
    idt_ptr.base  = (uint64_t)&idt;

    asm volatile("lidt %0" : : "m"(idt_ptr) : "memory");
}

void set_idt_entry_stub(int vector, isr_stub_t handler, uint8_t ist, uint8_t type_attr) {
    uint64_t addr = (uint64_t)handler;

    idt[vector].offset_low  = addr & 0xFFFF;
    idt[vector].offset_mid  = (addr >> 16) & 0xFFFF;
    idt[vector].offset_high = (addr >> 32) & 0xFFFFFFFF;

    idt[vector].selector    = 0x08;
    idt[vector].ist         = ist;
    idt[vector].type_attr   = type_attr;
    idt[vector].zero        = 0;
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
    (void)error_code;
    panic_reason = "PAGE FAULT";
    panic_handler_c(frame);
    for(;;) asm volatile("cli; hlt");
}

__attribute__((interrupt))
void double_fault_handler(struct InterruptFrame* frame, uint64_t error_code) {
    (void)error_code;
    panic_reason = "DOUBLE FAULT";
    panic_handler_c(frame);
    for(;;) asm volatile("cli; hlt");
}

__attribute__((interrupt))
void general_protection_handler(struct InterruptFrame* frame, uint64_t error_code) {
    (void)error_code;
    panic_reason = "GENERAL PROTECTION";
    panic_handler_c(frame);
    for(;;) asm volatile("cli; hlt");
}

__attribute__((interrupt))
void invalid_opcode_handler(struct InterruptFrame* frame, uint64_t error_code) {
    (void)error_code;
    (void)frame;
    panic_reason = "INVALID OPCODE";
    asm volatile (".global panic_handler_c; call panic_handler_c");
}

void panic_handler_c(struct InterruptFrame* frame) {
    panic(panic_reason, frame);
}
