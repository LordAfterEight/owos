.global enable_sse
enable_sse:
    mov %cr0, %rax
    and $~(1<<2), %rax      # clear EM
    and $~(1<<3), %rax      # clear TS
    or  $(1<<1), %rax       # set MP
    mov %rax, %cr0

    mov %cr4, %rax
    or  $(1<<9), %rax
    or  $(1<<10), %rax
    mov %rax, %cr4
    ret
