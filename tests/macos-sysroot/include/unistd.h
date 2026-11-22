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

/* _SC_OPEN_MAX is the BSD value (5) on macOS; an assumption checked by the Mac run (IO fd limit). */
#define _SC_OPEN_MAX 5
long sysconf(int name);

int access(const char *path, int mode);
int close(int fd);
int dup(int fd);
int dup2(int fd, int fd2);
int isatty(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
ssize_t pread(int fd, void *buf, size_t count, off_t offset);
ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset);
off_t lseek(int fd, off_t offset, int whence);
int ftruncate(int fd, off_t length);
int truncate(const char *path, off_t length);
int pipe(int fds[2]);
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
int unlink(const char *path);
int rmdir(const char *path);
int link(const char *path1, const char *path2);
int symlink(const char *path1, const char *path2);
ssize_t readlink(const char *path, char *buf, size_t bufsize);
int chown(const char *path, uid_t owner, gid_t group);
int rename(const char *from, const char *to);
pid_t fork(void);
pid_t getpid(void);
pid_t getppid(void);
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
unsigned int sleep(unsigned int seconds);
void _exit(int status);
int execl(const char *path, const char *arg0, ...);

#ifdef __cplusplus
}
#endif
#endif
