/*
 * sys/stat.h for the clean-room macOS sysroot. Function prototypes are POSIX.1-2008. struct stat and the S_IF* values are
 * NOT fixed by POSIX.1: this layout is the arm64 macOS one as the assumption below, and is checked by the Mac run
 * (mruby's File.size, File.stat and file-type tests). Assumed layout, byte offsets, arm64 macOS, 64-bit inodes:
 *   dev 0 (int32), mode 4 (uint16), nlink 6 (uint16), ino 8 (uint64), uid 16, gid 20, rdev 24 (int32),
 *   atime 32, mtime 48, ctime 64, birthtime 80 (each struct timespec, 16 bytes), size 96 (off_t),
 *   blocks 104, blksize 112 (int32), flags 116 (uint32), gen 120 (uint32), lspare 124 (int32), qspare 128 (2 x int64).
 * Total 144 bytes. Not Apple's header.
 */
#ifndef _SYS_STAT_H_
#define _SYS_STAT_H_

#include <sys/types.h>
#include <stdint.h>
#include <time.h>

struct stat {
  dev_t st_dev;
  mode_t st_mode;
  nlink_t st_nlink;
  ino_t st_ino;
  uid_t st_uid;
  gid_t st_gid;
  dev_t st_rdev;
  struct timespec st_atimespec;
  struct timespec st_mtimespec;
  struct timespec st_ctimespec;
  struct timespec st_birthtimespec;
  off_t st_size;
  blkcnt_t st_blocks;
  blksize_t st_blksize;
  uint32_t st_flags;
  uint32_t st_gen;
  int32_t st_lspare;
  int64_t st_qspare[2];
};

#define st_atime st_atimespec.tv_sec
#define st_mtime st_mtimespec.tv_sec
#define st_ctime st_ctimespec.tv_sec

/* The file-type and permission bits: the values the BSD family and Linux share (not fixed by POSIX.1). */
#define S_IFMT   0170000
#define S_IFIFO  0010000
#define S_IFCHR  0020000
#define S_IFDIR  0040000
#define S_IFBLK  0060000
#define S_IFREG  0100000
#define S_IFLNK  0120000
#define S_IFSOCK 0140000
#define S_ISUID  0004000
#define S_ISGID  0002000
#define S_ISVTX  0001000
#define S_IRWXU  0000700
#define S_IRUSR  0000400
#define S_IWUSR  0000200
#define S_IXUSR  0000100
#define S_IRWXG  0000070
#define S_IRGRP  0000040
#define S_IWGRP  0000020
#define S_IXGRP  0000010
#define S_IRWXO  0000007
#define S_IROTH  0000004
#define S_IWOTH  0000002
#define S_IXOTH  0000001

#define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
#define S_ISLNK(m)  (((m) & S_IFMT) == S_IFLNK)
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#define S_ISCHR(m)  (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)  (((m) & S_IFMT) == S_IFBLK)
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)

int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);
int lstat(const char *path, struct stat *buf);
int chmod(const char *path, mode_t mode);
int fchmod(int fd, mode_t mode);
int mkdir(const char *path, mode_t mode);
mode_t umask(mode_t cmask);

#endif /* _SYS_STAT_H_ */
