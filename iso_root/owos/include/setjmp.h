#ifndef SETJMP_H
#define SETJMP_H

typedef struct {
    unsigned long long regs[8];
} jmp_buf;

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

#endif