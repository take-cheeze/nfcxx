/* Clean-room time.h: declarations from C11 7.27 (Date and time). Written from the standard, not from any SDK. */
#ifndef CLEANROOM_TIME_H
#define CLEANROOM_TIME_H
#ifdef __cplusplus
extern "C" {
#endif

/* C++ has no restrict keyword: map it to __restrict here (compile checks only). */
#if defined(__cplusplus)
#define restrict __restrict
#endif

#include <stddef.h>

#ifndef CLEANROOM_TIME_T
#define CLEANROOM_TIME_T
typedef long time_t;
typedef long clock_t;
#endif

#define CLOCKS_PER_SEC ((clock_t)1000000)

struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
};

struct timespec {
  time_t tv_sec;
  long tv_nsec;
};

clock_t clock(void);
double difftime(time_t, time_t);
time_t mktime(struct tm *);
time_t time(time_t *);
char *asctime(const struct tm *);
char *ctime(const time_t *);
struct tm *gmtime(const time_t *);
struct tm *localtime(const time_t *);
size_t strftime(char *restrict, size_t, const char *restrict, const struct tm *restrict);

/* POSIX (time.h): the sleep that libc++'s threading layer uses */
int nanosleep(const struct timespec *, struct timespec *);
#ifndef CLEANROOM_CLOCKID_T
#define CLEANROOM_CLOCKID_T
typedef int clockid_t;
#endif
/* POSIX.1-2008 <time.h> requires CLOCK_REALTIME; 0 is the wall clock on the target (checked on the Mac). */
#define CLOCK_REALTIME 0
/* CLOCK_MONOTONIC and CLOCK_MONOTONIC_RAW: Apple's public Libc include/_time.h (commit 71bbe350ab79eef58113991d817ccc6165061a64). */
#define CLOCK_MONOTONIC 6
#define CLOCK_MONOTONIC_RAW 4
int clock_gettime(clockid_t, struct timespec *);

/* POSIX.1-2008 reentrant time conversions, from the specification. */
struct tm *gmtime_r(const time_t *timer, struct tm *result);
struct tm *localtime_r(const time_t *timer, struct tm *result);
char *asctime_r(const struct tm *tm, char *buf);
char *ctime_r(const time_t *timer, char *buf);
#ifdef __cplusplus
}
#endif

#endif
