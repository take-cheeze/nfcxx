/* POSIX.1-2008 <sys/time.h>: struct timeval and gettimeofday. Written from the POSIX specification, for compile checks. */
#ifndef NFCXX_CLEANROOM_SYS_TIME_H
#define NFCXX_CLEANROOM_SYS_TIME_H
#include <sys/types.h>
#include <time.h>
struct timeval { time_t tv_sec; long tv_usec; };
struct timezone { int tz_minuteswest; int tz_dsttime; };
#ifdef __cplusplus
extern "C" {
#endif
int gettimeofday(struct timeval *tv, void *tz);
#ifdef __cplusplus
}
#endif
#endif
