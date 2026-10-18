/*
 * sys/types.h for the clean-room macOS sysroot (tests/macos-sysroot). ssize_t and off_t are fixed by POSIX.1 (signed,
 * the width of size_t, and a 64-bit signed offset on arm64 macOS). The other types below have platform-chosen widths that
 * POSIX.1 does not fix. Their widths here are the ones the arm64 macOS ABI uses, stated as assumptions, not read from any
 * Apple header: mode_t uint16, pid_t int32, uid_t and gid_t uint32, dev_t int32, ino_t uint64, nlink_t uint16,
 * blksize_t int32, blkcnt_t int64. They are checked by the Mac run (mruby's File.size, File.file? and friends), so a wrong
 * width shows as a wrong result there. Not Apple's header.
 */
#ifndef _SYS_TYPES_H_
#define _SYS_TYPES_H_

#include <stddef.h>
#include <stdint.h>

typedef long ssize_t;
typedef long long off_t;
typedef int32_t pid_t;
typedef uint32_t uid_t;
typedef uint32_t gid_t;
typedef uint16_t mode_t;
typedef int32_t dev_t;
typedef uint64_t ino_t;
typedef uint16_t nlink_t;
typedef int32_t blksize_t;
typedef int64_t blkcnt_t;

#endif /* _SYS_TYPES_H_ */
