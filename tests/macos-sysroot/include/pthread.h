/* Clean-room declarations of the POSIX threads functions used by libc++'s threading layer, from the POSIX
 * specification (pthread.h). Compile checks only. The mutex, condition, once and attribute types follow the LP64 layouts and
 * initializer signatures of Apple's open-source libpthread (_pthread_types.h and types_internal.h), so a binary's objects
 * match the Mac's libSystem. */
#ifndef NFCXX_CLEANROOM_PTHREAD_H
#define NFCXX_CLEANROOM_PTHREAD_H

#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __nfcxx_pthread;
typedef struct __nfcxx_pthread *pthread_t;   /* a pointer, as on Darwin, so thread ids compare with == */
typedef struct { long __sig; char __opaque[56]; } pthread_attr_t;
typedef struct { long __sig; char __opaque[56]; } pthread_mutex_t;
typedef struct { long __sig; char __opaque[8]; } pthread_mutexattr_t;
typedef struct { long __sig; char __opaque[40]; } pthread_cond_t;
typedef struct { long __sig; char __opaque[8]; } pthread_condattr_t;
typedef struct { long __sig; char __opaque[8]; } pthread_once_t;
typedef unsigned long pthread_key_t;

#define PTHREAD_MUTEX_NORMAL 0
#define PTHREAD_MUTEX_RECURSIVE 2
#define PTHREAD_MUTEX_ERRORCHECK 1
#define PTHREAD_MUTEX_INITIALIZER {0x32AAABA7, {0}}
#define PTHREAD_COND_INITIALIZER {0x3CB0B1BB, {0}}
#define PTHREAD_ONCE_INIT {0x30B1BCBA, {0}}

int pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int pthread_join(pthread_t, void **);
int pthread_detach(pthread_t);
pthread_t pthread_self(void);

int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_trylock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);

int pthread_mutexattr_init(pthread_mutexattr_t *);
int pthread_mutexattr_destroy(pthread_mutexattr_t *);
int pthread_mutexattr_settype(pthread_mutexattr_t *, int);

int pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int pthread_cond_destroy(pthread_cond_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);

int pthread_once(pthread_once_t *, void (*)(void));

int pthread_key_create(pthread_key_t *, void (*)(void *));
int pthread_key_delete(pthread_key_t);
void *pthread_getspecific(pthread_key_t);
int pthread_setspecific(pthread_key_t, const void *);

#ifdef __cplusplus
}
#endif

#endif
