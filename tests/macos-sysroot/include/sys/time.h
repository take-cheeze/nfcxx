/*
 * sys/time.h for the clean-room macOS sysroot. struct timeval and gettimeofday are the BSD and POSIX interfaces; the
 * timeval layout is two time_t-width fields, as the assumption here. Not Apple's header.
 */
#ifndef _SYS_TIME_H_
#define _SYS_TIME_H_

#include <sys/types.h>
#include <time.h>

typedef int32_t suseconds_t;

struct timeval {
  time_t tv_sec;
  suseconds_t tv_usec;
};

int gettimeofday(struct timeval *tv, void *tz);

#include <sys/select.h>

#endif /* _SYS_TIME_H_ */
