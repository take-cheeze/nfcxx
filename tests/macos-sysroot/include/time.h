/* Clean-room time.h: declarations from C11 7.27 (Date and time). Written from the standard, not from any SDK. */
#ifndef CLEANROOM_TIME_H
#define CLEANROOM_TIME_H
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

#endif
