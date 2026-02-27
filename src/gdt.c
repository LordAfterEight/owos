#include "gdt.h"
#include <stdint.h>

void create_descriptor(uint32_t base, uint32_t limit, uint16_t flag) {
    uint64_t descriptor;

    descriptor  =  limit       & 0x000F0000;
    descriptor |= (flag <<  8) & 0x00F0FF00;
    descriptor |= (base >> 16) & 0x000000FF;
    descriptor |=  base        & 0xFF000000;

    descriptor <<= 32;

    descriptor |= base  << 16;
    descriptor |= limit  & 0x0000FFFF;
}

void gdt_init(void) {
    // Zero TSS
    for (int i = 0; i < sizeof(tss); i++) {
        ((uint8_t*)&tss)[i] = 0;
    }

    // Set up double fault stack (IST1)
    tss.ist1 = (uint64_t)double_fault_stack + sizeof(double_fault_stack);

    // GDT entries
    gdt[0] = 0;  // Null descriptor
    gdt[1] = 0x00AF9B000000FFFF;  // Code segment
    gdt[2] = 0x00CF93000000FFFF;  // Data segment

    // TSS descriptor (16 bytes in x86_64, occupies gdt[3] and gdt[4])
    uint64_t tss_base = (uint64_t)&tss;
    uint64_t tss_limit = sizeof(struct TSS64) - 1;

    // Low 64 bits of TSS descriptor
    gdt[3] = (tss_limit & 0xFFFF) |              // Limit 15:0
    ((tss_base & 0xFFFF) << 16) |       // Base 15:0
    (((tss_base >> 16) & 0xFF) << 32) | // Base 23:16
    (0x89ULL << 40) |                   // Type=0x9 (Available TSS), P=1
    ((tss_limit & 0xF0000) << 32) |     // Limit 19:16
    (((tss_base >> 24) & 0xFF) << 56);  // Base 31:24

    // High 64 bits of TSS descriptor (upper 32 bits of base address)
    gdt[4] = (tss_base >> 32);

    struct {
        uint16_t limit;
        uint64_t base;
    } __attribute__((packed)) gdtr = {
        .limit = sizeof(gdt) - 1,
        .base  = (uint64_t)&gdt[0]
    };

    asm volatile (
        "lgdt %0\n\t"
        "mov $0x10, %%ax\n\t"
        "mov %%ax, %%ds\n\t"
        "mov %%ax, %%es\n\t"
        "mov %%ax, %%fs\n\t"
        "mov %%ax, %%gs\n\t"
        "mov %%ax, %%ss\n\t"
        "pushq $0x08\n\t"
        "lea 1f(%%rip), %%rax\n\t"
        "push %%rax\n\t"
        "lretq\n\t"
        "1:\n\t"
        // Load TSS (selector 0x18 = index 3 in GDT)
        "mov $0x18, %%ax\n\t"
        "ltr %%ax\n\t"
        : : "m"(gdtr)
        : "rax", "memory"
    );
}

void tss_set_rsp0(uint64_t rsp0) {
    tss.rsp0 = rsp0;
}
