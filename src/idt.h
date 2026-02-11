#ifndef IDT
#define IDT

#include <stdint.h>

struct IDTEntry {
    uint16_t offset_low;
    uint16_t selector;
    uint8_t ist;
    uint8_t type_attr;
    uint16_t offset_mid;
    uint32_t offset_high;
    uint32_t zero;
};

struct __attribute__((packed)) IDTPointer {
    uint16_t limit;
    uint64_t base;
};

struct InterruptFrame {
    uint64_t ip;
    uint64_t cs;
    uint64_t flags;
    uint64_t sp;
    uint64_t ss;
};

typedef void (*interrupt_handler_t)(struct InterruptFrame *, uint64_t error_code);

__attribute__((aligned(32)))
extern struct IDTEntry idt[256];

__attribute__((aligned(32)))
extern struct IDTPointer idt_ptr;

void set_idt_entry(int vector, interrupt_handler_t handler, uint8_t ist, uint8_t type_attr);
bool check_idt_entry(int vector, interrupt_handler_t handler, uint8_t ist, uint8_t type_attr);
void idt_init(void);
extern void timer_handler_asm();

__attribute__((interrupt))
void default_handler(struct InterruptFrame* frame);

__attribute__((interrupt))
void default_handler_err(struct InterruptFrame* frame, uint64_t error_code);

__attribute__((interrupt))
void page_fault_handler(struct InterruptFrame* frame, uint64_t error_code);

__attribute__((interrupt))
void double_fault_handler(struct InterruptFrame* frame, uint64_t error_code);

__attribute__((noreturn))
void panic_handler_c(struct InterruptFrame* frame);

#endif
