/*
 * fcntl.h for the clean-room macOS sysroot. The function and the F_GETFD/F_SETFD/F_GETFL/F_SETFL command names are
 * POSIX.1-2008. The O_* and FD_CLOEXEC values are NOT fixed by POSIX.1: these are the arm64 macOS values, stated as an
 * assumption and checked by the Mac run (File open modes and close-on-exec). Not Apple's header.
 */
#ifndef _FCNTL_H_
#define _FCNTL_H_

#include <sys/types.h>

#define O_RDONLY   0x0000
#define O_WRONLY   0x0001
#define O_RDWR     0x0002
#define O_ACCMODE  0x0003
#define O_NONBLOCK 0x0004
#define O_APPEND   0x0008
#define O_CREAT    0x0200
#define O_TRUNC    0x0400
#define O_EXCL     0x0800
#define O_NOFOLLOW 0x0100
#define O_DIRECTORY 0x100000
#define O_CLOEXEC  0x1000000

#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define FD_CLOEXEC 1

int open(const char *path, int oflag, ...);
int fcntl(int fd, int cmd, ...);

#endif /* _FCNTL_H_ */
