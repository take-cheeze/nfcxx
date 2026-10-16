/* Clean-room unistd.h: the POSIX.1-2008 declarations that mruby's core (src/print.c) uses, written from the POSIX
 * specification, not from any SDK. Declarations and the standard constants only; the Mac run is the check. */
#ifndef CLEANROOM_UNISTD_H
#define CLEANROOM_UNISTD_H
#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <sys/types.h>

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4

int access(const char *path, int mode);
int close(int fd);
int dup(int fd);
int isatty(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);

#ifdef __cplusplus
}
#endif
#endif
