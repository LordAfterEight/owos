#include <stdint.h>
#include "std.h"
#include "shell/shell_definitions.h"
#include "idt.h"
#include "fonts/OwOSFont_8x16.h"

__attribute__((packed))
struct IDTEntry idt[256] __attribute__((aligned(16)));

__attribute__((packed))
struct IDTPointer idt_ptr __attribute__((aligned(16)));

void set_idt_entry(int vector, void *handler, uint8_t ist, uint8_t type_attr) {
    uint64_t addr = (uint64_t)handler;

    idt[vector].offset_low  = addr & 0xFFFF;
    idt[vector].offset_mid  = (addr >> 16) & 0xFFFF;
    idt[vector].offset_high = (addr >> 32) & 0xFFFFFFFF;

    idt[vector].selector    = 0x08;
    idt[vector].ist         = ist;
    idt[vector].type_attr   = type_attr;
    idt[vector].zero        = 0;
}

bool check_idt_entry(int vector, void *handler, uint8_t ist, uint8_t type_attr) {
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
    idt_ptr.limit = sizeof(idt) - 1;
    idt_ptr.base  = (uint64_t)&idt;

    asm volatile("lidt %0" : : "m"(idt_ptr) : "memory");
}

__attribute__((interrupt))
void default_handler(struct InterruptFrame* frame) {
    panic("Unhandleable Interrupt");
    asm volatile (
        "cli                        \n\t"
        "mov    %%rsp, %%rdi        \n\t"
        "call   panic_handler_c     \n\t"
        "1: hlt                     \n\t"
        "jmp    1b                  \n\t"
        ::: "memory", "rdi"
    );
}

__attribute__((interrupt))
void page_fault_handler(struct InterruptFrame* frame) {
    panic("Page Fault");
    asm volatile (
        "cli                        \n\t"
        "mov    %%rsp, %%rdi        \n\t"
        "call   panic_handler_c     \n\t"
        "1: hlt                     \n\t"
        "jmp    1b                  \n\t"
        ::: "memory", "rdi"
    );
}

__attribute__((interrupt))
void double_fault_handler(struct InterruptFrame* frame) {
    panic("Double Fault");
    asm volatile (
        "cli                        \n\t"
        "mov    %%rsp, %%rdi        \n\t"
        "call   panic_handler_c     \n\t"
        "1: hlt                     \n\t"
        "jmp    1b                  \n\t"
        ::: "memory", "rdi"
    );
}

__attribute__((noreturn))
void panic_handler_c(struct InterruptFrame* frame) {
    char buf[64];
    format(buf, "Instruction Pointer: 0x%x", frame->ip);
    draw_text(1, 1, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    format(buf, "Stack Pointer: 0x%x", frame->sp);
    draw_text(1, 17, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    while(1) asm volatile("hlt");
}
