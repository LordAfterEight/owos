#include "shell_definitions.h"
#include "fonts/OwOSFont_8x16.h"

int start_shell(struct Shell shell) {
    shell_print(&shell, "Command: ", 0xAAAAAA, false, &OwOSFont_8x16);
    while (1) {
        update_shell(&shell);
    }
    return 0;
}
