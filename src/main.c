#include "prerequisites.h"
#include "rendering.h"
#include "std.h"
#include "shell.h"
#include "timer.h"
#include "idt.h"
#include "gdt.h"
#include "pic.h"

#include "fonts/OwOSFont_8x8.h"
#include "fonts/OwOSFont_8x16.h"

static void hcf(void) {
    for (;;) {
        asm ("hlt");
    }
}

void kmain(void) {
    if (LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision) == false) {
        hcf();
    }

    if (framebuffer_request.response == NULL
     || framebuffer_request.response->framebuffer_count < 1) {
        hcf();
    }

    struct limine_framebuffer *framebuffer = framebuffer_request.response->framebuffers[0];

    global_framebuffer = (volatile uint32_t*)framebuffer->address;

    struct InputBuffer input_buffer = {
        buffer: {' '},
        buffer_pos: 0,
    };

    struct Cursor cursor = {
        pos_x: 1,
        pos_y: 1,
        visible: true,
        last_toggle: ticks,
    };

    struct Shell shell = {
        buffer: input_buffer,
        cursor: cursor,
    };

    gdt_init();

    create_descriptor(0, 0, 0);
    create_descriptor(0, 0x000FFFFF, (GDT_CODE_PL0));
    create_descriptor(0, 0x000FFFFF, (GDT_DATA_PL0));
    create_descriptor(0, 0x000FFFFF, (GDT_CODE_PL3));
    create_descriptor(0, 0x000FFFFF, (GDT_DATA_PL3));

    pic_remap();

    char buf[64];
    format(buf, "Pushing default handler address (0x%x) to interrupt descriptor table", default_handler);
    shell_println(&shell, buf, 0xFFFFFF, false, &OwOSFont_8x16);
    draw_text(640, 1, "IDT Vectors:", 0xAAFFAA, false, &OwOSFont_8x16);
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 8; x++) {
            set_idt_entry(x+8*y, default_handler, 0, 0x8E);
        }
    }
    set_idt_entry(32, timer_callback, 0, 0x8E);
    set_idt_entry(8, double_fault_handler, 1, 0x8E);
    set_idt_entry(13, page_fault_handler, 1, 0x8E);
    set_idt_entry(14, double_fault_handler, 1, 0x8E);
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 8; x++) {
            char buf[16];
            format(buf, "vector %d: 0x%x", x+8*y, idt[x+8*y]);
            draw_text(640 + x*160, 20 + y*16, buf, 0xFFAAAA, false, &OwOSFont_8x16);
        }
    }
    idt_init();

    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);

    outb(PIC1_DATA, inb(PIC1_DATA) & ~(1 << 0));

    pit_init(&shell, 1000);

    asm volatile ("sti");

    shell_println(&shell, "", 0x000000, false, &OwOSFont_8x16);

    shell_println(&shell, "Welcome to the OwOS-C kernel!", 0x66FF66, false, &OwOSFont_8x16);
    shell_println(&shell, "Ver 0.1.0", 0xFF6666, false, &OwOSFont_8x16);
    shell_print(&shell, "Build date: ", 0xDDDDDD, false, &OwOSFont_8x16);
    shell_println(&shell, __DATE__, 0x6666FF, false, &OwOSFont_8x16);
    shell_println(&shell, "", 0xFFFFFF, false, &OwOSFont_8x16);

    int result = start_shell(shell);
    switch (result) {
        case 1: panic(" Shell crashed with exit code 1");
        case 0: hcf();
        default: panic(" Invalid return code ");
    }
}
