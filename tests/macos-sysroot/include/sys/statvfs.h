/*
 * sys/statvfs.h for the clean-room macOS sysroot. Written from the POSIX.1-2008 <sys/statvfs.h> interface only:
 * the member names and the statvfs/fstatvfs functions. Widths are chosen here (uint64_t) and are not ABI-checked.
 */
#ifndef NFCXX_CLEANROOM_SYS_STATVFS_H
#define NFCXX_CLEANROOM_SYS_STATVFS_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t fsblkcnt_t;
typedef uint64_t fsfilcnt_t;

struct statvfs {
  unsigned long f_bsize;   /* file system block size */
  unsigned long f_frsize;  /* fundamental file system block size */
  fsblkcnt_t f_blocks;     /* total blocks */
  fsblkcnt_t f_bfree;      /* free blocks */
  fsblkcnt_t f_bavail;     /* free blocks available to unprivileged users */
  fsfilcnt_t f_files;      /* total file nodes */
  fsfilcnt_t f_ffree;      /* free file nodes */
  fsfilcnt_t f_favail;     /* free file nodes available to unprivileged users */
  unsigned long f_fsid;    /* file system ID */
  unsigned long f_flag;    /* mount flags */
  unsigned long f_namemax; /* maximum file name length */
};

int statvfs(const char *restrict, struct statvfs *restrict);
int fstatvfs(int, struct statvfs *);

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_SYS_STATVFS_H */
