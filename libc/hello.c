#include <owos/print.h>

int main(void) {
    for (int i = 0; i <= 10; i++) {
        println("hello from OwOS libc (i=%d)", i);
    }
    return 0;
}