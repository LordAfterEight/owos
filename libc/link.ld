ENTRY(_start)

/* Must match .jit_exec in the kernel linker script. */
JIT_BASE = 0xffffffff81000000;

SECTIONS
{
    . = JIT_BASE;
    __load_base = .;

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    __load_end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.eh_frame*)
        *(.comment)
    }
}