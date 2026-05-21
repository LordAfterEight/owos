ENTRY(start)

PHDRS {
    text    PT_LOAD FLAGS(5);
    rodata  PT_LOAD FLAGS(4);
    data    PT_LOAD FLAGS(6);
}

SECTIONS {
    . = 0xffffffff80000000;

    .text : { *(.text .text.*) } :text

    .rodata : { *(.rodata .rodata.*) } :rodata

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :rodata

    .data : { *(.data .data.*) } :data

    .bss : { *(.bss .bss.*) } :data
}
