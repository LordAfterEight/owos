ENTRY(_start)

SECTIONS {
    . = 0xFFFFFFFF80200000;

    .text ALIGN(4K) : {
        *(.text .text.*)
    }

    .rodata ALIGN(4K) : {
        *(.rodata .rodata.*)
    }

    .limine_requests_start ALIGN(4K) : {
        KEEP(*(.limine_requests_start))
    }

    .limine_requests ALIGN(4K) : {
        KEEP(*(.limine_requests .limine_requests.*))
    }

    .limine_requests_end ALIGN(4K) : {
        KEEP(*(.limine_requests_end))
    }

    .data ALIGN(4K) : {
        *(.data .data.*)
    }

    .bss ALIGN(4K) : {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(16);
        __stack_bottom = .;
        . += 16K;
        __stack_top = .;
    }
}
