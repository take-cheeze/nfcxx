/* Clean-room minimal <errno.h> for macOS arm64 compile checks (C11 7.5, POSIX). The errno lvalue is Darwin's
 * public libc convention (__error()). Compile checks only. */
#ifndef CLEANROOM_ERRNO_H
#define CLEANROOM_ERRNO_H
#ifdef __cplusplus
extern "C" {
#endif

extern int *__error(void);
#define errno (*__error())
#define EDOM 33
#define ERANGE 34
#define EILSEQ 92
#define ENOENT 2
#define EINVAL 22
#define ENOMEM 12
#define EINTR 4
#define EAGAIN 35
#ifdef __cplusplus
}
#endif

/* POSIX.1 error names; the values are the BSD numbering the arm64 macOS errno uses (assumption, see the Mac run). */
#define EPERM 1
#define ESRCH 3
#define EIO 5
#define ENXIO 6
#define E2BIG 7
#define ENOEXEC 8
#define EBADF 9
#define ECHILD 10
#define EDEADLK 11
#define EACCES 13
#define EFAULT 14
#define EBUSY 16
#define EEXIST 17
#define EXDEV 18
#define ENODEV 19
#define ENOTDIR 20
#define EISDIR 21
#define ENFILE 23
#define EMFILE 24
#define ENOTTY 25
#define EFBIG 27
#define ENOSPC 28
#define ESPIPE 29
#define EROFS 30
#define EMLINK 31
#define EPIPE 32
#define EWOULDBLOCK 35
#define EINPROGRESS 36
#define ENAMETOOLONG 63
#define ENOTEMPTY 66
#define ELOOP 62
#define ETIMEDOUT 60
#define ECONNREFUSED 61
#define ENOTSUP 45
#define EOPNOTSUPP 102
#endif
