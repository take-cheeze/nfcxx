/* Clean-room declaration of sched_yield from the POSIX specification (sched.h). Compile checks only. */
#ifndef NFCXX_CLEANROOM_SCHED_H
#define NFCXX_CLEANROOM_SCHED_H

#ifdef __cplusplus
extern "C" {
#endif

int sched_yield(void);

#ifdef __cplusplus
}
#endif

#endif
