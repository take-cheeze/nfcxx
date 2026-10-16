/*
 * sys/types.h for the clean-room macOS sysroot (tests/macos-sysroot). Written from POSIX.1 for the types whose meaning and
 * width the standard fixes: ssize_t (signed, the width of size_t) and off_t (a signed integer type, 64-bit on arm64 macOS).
 * Not Apple's header. The POSIX types with platform-chosen widths (mode_t, pid_t, uid_t, gid_t, dev_t, ino_t) are left out:
 * nothing in the cross build's gem set uses them, and guessing their widths would misdescribe the Darwin ABI.
 */
#ifndef _SYS_TYPES_H_
#define _SYS_TYPES_H_

#include <stddef.h>

typedef long ssize_t;
typedef long long off_t;

#endif /* _SYS_TYPES_H_ */
