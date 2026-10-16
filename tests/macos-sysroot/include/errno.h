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

#endif
