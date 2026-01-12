#include "shell_definitions.h"

int start_shell(uint32_t* framebuffer) {
    struct InputBuffer input_buffer = {
        buffer: {' '},
        buffer_pos: 0,
    };

    struct Cursor cursor = {
        pos_x: 1,
        pos_y: 1,
        visible: true,
        counter: 0,
        threshold: 100000,
    };

    struct Shell shell = {
        buffer: input_buffer,
        cursor: cursor,
    };


    shell_println(framebuffer, &shell, "Welcome to the OwOS-C kernel!", 0x66FF66, false);
    shell_println(framebuffer, &shell, "Ver 0.1.0", 0xFF6666, false);
    shell_print(framebuffer, &shell, "Build date: ", 0xDDDDDD, false);
    shell_println(framebuffer, &shell, __DATE__, 0x6666FF, false);
    shell_println(framebuffer, &shell, "", 0xFFFFFF, false);
    shell_print(framebuffer, &shell, "Command: ", 0xAAAAAA, false);
    while (1) {
        update_shell(framebuffer, &shell);
    }
    return 0;
}

