/* POSIX.1-2008 <unistd.h>: the process and file calls doctest uses. Written from the POSIX specification, for compile checks. */
#ifndef NFCXX_CLEANROOM_UNISTD_H
#define NFCXX_CLEANROOM_UNISTD_H
#include <sys/types.h>
#include <stddef.h>
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#ifdef __cplusplus
extern "C" {
#endif
pid_t getpid(void);
unsigned int sleep(unsigned int);
int isatty(int);
ssize_t write(int, const void *, size_t);
ssize_t read(int, void *, size_t);
int close(int);
int dup2(int, int);
int pipe(int[2]);
#ifdef __cplusplus
}
#endif
#endif
