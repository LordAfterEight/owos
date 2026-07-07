#ifndef SIGNAL_H
#define SIGNAL_H

typedef void (*sighandler_t)(int);

#define SIGFPE   8
#define SIGILL   4
#define SIGSEGV  11
#define SIGBUS   7
#define SIGABRT  6

#define SA_SIGINFO  4
#define SA_RESETHAND 0x80000000

union sigval {
    int sival_int;
    void *sival_ptr;
};

#define FPE_INTDIV 1
#define FPE_FLTDIV 3

typedef struct {
    int si_signo;
    int si_errno;
    int si_code;
    void *si_addr;
} siginfo_t;

struct sigaction {
    union {
        sighandler_t sa_handler;
        void (*sa_sigaction)(int, siginfo_t *, void *);
    };
    unsigned long sa_flags;
    void (*sa_restorer)(void);
    unsigned long sa_mask;
};

int sigemptyset(unsigned long *set);
int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact);

#endif