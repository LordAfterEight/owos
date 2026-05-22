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
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :kernel

    . = ALIGN(0x1000);
    .data : { *(.data .data.*) } :kernel

    .bss (NOLOAD) : { *(.bss .bss.*) } :kernel
}