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

void (*signal(int sig, void (*func)(int)))(int);
int raise(int sig);

#ifdef __cplusplus
}
#endif
#endif
