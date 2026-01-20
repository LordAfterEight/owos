#include <stdint.h>
#include "std/std.h"
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
    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Timer Callback", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(32, timer_callback, 0, 0x8E);

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Double Fault Handler", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(8, double_fault_handler, 1, 0x8E);

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Page Fault Handler", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(14, page_fault_handler, 1, 0x8E);

    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Checking Entries...", 0xFFFF77, false, &OwOSFont_8x16);

    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(32, timer_callback, 0, 0x8E)) {
        shell_println("Timer Callback [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("Timer Callback [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(8, double_fault_handler, 1, 0x8E)) {
        shell_println("DF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("DF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(14, page_fault_handler, 1, 0x8E)) {
        shell_println("PF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("PF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    idt_ptr.limit = sizeof(idt) - 1;
    idt_ptr.base  = (uint64_t)&idt;

    asm volatile("lidt %0" : : "m"(idt_ptr) : "memory");
}

__attribute__((interrupt))
void default_handler(struct InterruptFrame* frame) {
    char buf[64];
    draw_char(shell.cursor.pos_x, shell.cursor.pos_y + 16, '^', 0x000000, false, &OwOSFont_8x16);
    shell.cursor.pos_x = 1;
    shell.cursor.pos_y += OwOSFont_8x16.height;
    shell_print("[Kernel:IDT] -> ", 0xAA77AA, false, &OwOSFont_8x16);
    shell_println("Interrupt ocurred", 0xFFFFFF, false, &OwOSFont_8x16);
    shell_print("Command: ", 0xAAAAAA, false, &OwOSFont_8x16);
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
