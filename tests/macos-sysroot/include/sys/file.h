/*
 * sys/file.h for the clean-room macOS sysroot. flock is POSIX-adjacent (BSD); the LOCK_* values are the BSD ones, the
 * same on arm64 macOS as the assumption here. Checked by the Mac run (File#flock). Not Apple's header.
 */
#ifndef _SYS_FILE_H_
#define _SYS_FILE_H_

#define LOCK_SH 0x01
#define LOCK_EX 0x02
#define LOCK_NB 0x04
#define LOCK_UN 0x08

int flock(int fd, int operation);

#endif /* _SYS_FILE_H_ */
