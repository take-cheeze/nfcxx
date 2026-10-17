/* Clean-room signal.h: declarations from C11 7.14 (Signal handling). Written from the standard, not from any SDK.
 * The signal numbers are the conventional POSIX values. They are compile-time constants here; the Mac run is the check. */
#ifndef CLEANROOM_SIGNAL_H
#define CLEANROOM_SIGNAL_H
#ifdef __cplusplus
extern "C" {
#endif

typedef int sig_atomic_t;

#define SIG_DFL ((void (*)(int))0)
#define SIG_ERR ((void (*)(int))-1)
#define SIG_IGN ((void (*)(int))1)

#define SIGABRT 6
#define SIGFPE 8
#define SIGILL 4
#define SIGINT 2
#define SIGSEGV 11
#define SIGTERM 15


/* POSIX.1-2008 sigaction family, from the POSIX specification: enough for doctest's stack-overflow handler. */
typedef int sigset_t;
#define SIGSTKSZ 16384
#define SA_ONSTACK 0x0001
#define SA_SIGINFO 0x0002
#define SA_RESTART 0x0004
#define SIGBUS 10
#define SIGTRAP 5
typedef struct { void *ss_sp; int ss_flags; unsigned long ss_size; } stack_t;
struct sigaction {
    void (*sa_handler)(int);
    sigset_t sa_mask;
    int sa_flags;
};
int sigaction(int sig, const struct sigaction *act, struct sigaction *oact);
int sigaltstack(const stack_t *ss, stack_t *oss);
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);

void (*signal(int sig, void (*func)(int)))(int);
int raise(int sig);

#ifdef __cplusplus
}
#endif
#endif
