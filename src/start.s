.section .bss
.align 16
.global __boot_stack_bottom
__boot_stack_bottom:
    .skip 65536              # 64 KiB stack
.global __boot_stack_top
__boot_stack_top:

.section .text
.global _start
.extern kmain

_start:
    lea __boot_stack_top(%rip), %rsp
    xor %rbp, %rbp
    cld
    call kmain

.hang:
    cli
    hlt
    jmp .hang
