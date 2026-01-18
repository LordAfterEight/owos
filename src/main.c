#include "prerequisites.h"
#include "rendering.h"
#include "std.h"
#include "shell/shell_definitions.h"
#include "timer.h"
#include "idt.h"
#include "gdt.h"
#include "pic.h"
#include "sound/pcspeaker.h"
#include "process/process.h"

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


    clear_screen(&shell);

    gdt_init();

    create_descriptor(0, 0, 0);
    create_descriptor(0, 0x000FFFFF, (GDT_CODE_PL0));
    create_descriptor(0, 0x000FFFFF, (GDT_DATA_PL0));
    create_descriptor(0, 0x000FFFFF, (GDT_CODE_PL3));
    create_descriptor(0, 0x000FFFFF, (GDT_DATA_PL3));

    pic_remap();
    shell_init();

    char buf[64];

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Default Handler", 0xFFFFFF, false, &OwOSFont_8x16);
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 8; x++) {
            set_idt_entry(x+8*y, default_handler, 0, 0x8E);
        }
    }

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Timer Callback", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(32, timer_callback, 0, 0x8E);

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Double Fault Handler", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(8, double_fault_handler, 1, 0x8E);

    shell_print("[Kernel:IDT] <- ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Page Fault Handler", 0xFFFFFF, false, &OwOSFont_8x16);
    set_idt_entry(14, page_fault_handler, 1, 0x8E);

    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    shell_println("Checking Entries...", 0xFFFF77, false, &OwOSFont_8x16);

    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(32, timer_callback, 0, 0x8E)) {
        shell_println("Timer Callback [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("Timer Callback [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(8, double_fault_handler, 1, 0x8E)) {
        shell_println("DF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("DF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);
    shell_print("[Kernel:IDT] -> ", 0xAAAAAA, false, &OwOSFont_8x16);
    if (check_idt_entry(14, page_fault_handler, 1, 0x8E)) {
        shell_println("PF Handler [OK]", 0x22FF22, false, &OwOSFont_8x16);
    } else shell_println("PF Handler [ERR]", 0xFF2222, false, &OwOSFont_8x16);

    idt_init();

    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);

    outb(PIC1_DATA, inb(PIC1_DATA) & ~(1 << 0));

    pit_init(&shell, 1000);

    asm volatile ("sti");

    shell_println("", 0x000000, false, &OwOSFont_8x16);

    greet();

    beep(1000, 50);

    int result = shell_process.run(shell);
    switch (result) {
        case 0: hcf();
        case 1: {
                panic(" Shell crashed with exit code 1");
                break;
        }
        case 2: {
            draw_rect_f(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0x000000);
            char buf[64];
            format(buf, "Kernel -> Ended process: %s (PID %d)", shell_process.name, shell_process.id);
            draw_text(1, 1, buf, 0xFFFFFF, false, &OwOSFont_8x16);
            msleep(2000);
            break;
        };
        default: {
            char buf[32];
            format(buf, " Invalid return code: %d ", result);
            panic(buf);
        };
    }
}
