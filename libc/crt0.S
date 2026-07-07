.section .text
.global _start

_start:
    xor %rbp, %rbp
    mov 8(%rsp), %rdi
    lea 16(%rsp), %rsi
    xor %rdx, %rdx
    call main
    mov %eax, %edi
    call exit
    hlt