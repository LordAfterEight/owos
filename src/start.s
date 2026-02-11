.global _start
_start:
    andq $-16, %rsp   # rsp % 16 == 0 before call
    call kmain
