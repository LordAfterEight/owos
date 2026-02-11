.section .text
.global timer_handler_asm
.extern ticks

timer_handler_asm:
    pushq %rax
    pushq %rdx

    incl ticks(%rip)

    movb $0x20, %al
    outb %al, $0x20

    popq %rdx
    popq %rax
    iretq
