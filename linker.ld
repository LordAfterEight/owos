ENTRY(start)

PHDRS {
    kernel PT_LOAD FLAGS(7);
}

SECTIONS {
    . = 0xffffffff80000000;

    .text : { *(.text .text.*) } :kernel

    . = ALIGN(0x1000);
    .rodata : { *(.rodata .rodata.*) } :kernel

    . = ALIGN(0x1000);
    .limine_requests : {
        KEEP(*(.limine_requests_start_marker))
        KEEP(*(.limine_base_revision))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end_marker))
    } :kernel

    . = ALIGN(0x1000);
    .data : { *(.data .data.*) } :kernel

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*)
        __bss_end = .;
    } :kernel

    /* Fixed load address for ring-0 JIT programs (must match libc/link.ld).
     * Placed high to stay clear of kernel .rodata (fonts, embedded binaries). */
    . = 0xffffffff81000000;
    .jit_exec 0xffffffff81000000 (NOLOAD) : {
        ASSERT(__bss_end <= 0xffffffff81000000, "kernel image overflowed jit_exec reservation");
        *(.jit_exec*)
    } :kernel

    /* Static malloc arena for large JIT programs (e.g. TCC). */
    . = 0xffffffff81500000;
    .jit_arena 0xffffffff81500000 (NOLOAD) : {
        *(.jit_arena*)
    } :kernel
}