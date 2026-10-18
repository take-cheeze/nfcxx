/* Clean-room declarations of the POSIX threads functions used by libc++'s threading layer, from the POSIX
 * specification (pthread.h). Compile checks only. The rwlock type follows the LP64 layout of Apple's open-source libpthread
 * (a signature word, then an opaque block), because libunwind's objects must match the Mac's libSystem; the other object
 * types are opaque placeholders, not Darwin's layouts. */
#ifndef NFCXX_CLEANROOM_PTHREAD_H
#define NFCXX_CLEANROOM_PTHREAD_H

#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __nfcxx_pthread;
typedef struct __nfcxx_pthread *pthread_t;   /* a pointer, as on Darwin, so thread ids compare with == */
typedef struct { long __opaque[8]; } pthread_attr_t;
typedef struct { long __opaque[8]; } pthread_mutex_t;
typedef struct { long __opaque[4]; } pthread_mutexattr_t;
typedef struct { long __opaque[8]; } pthread_cond_t;
typedef struct { long __opaque[4]; } pthread_condattr_t;
typedef struct { long __opaque[4]; } pthread_once_t;
typedef unsigned long pthread_key_t;
typedef struct { long __sig; char __opaque[192]; } pthread_rwlock_t;
typedef struct { long __sig; char __opaque[16]; } pthread_rwlockattr_t;

#define PTHREAD_MUTEX_NORMAL 0
#define PTHREAD_MUTEX_RECURSIVE 2
#define PTHREAD_MUTEX_ERRORCHECK 1
#define PTHREAD_MUTEX_INITIALIZER {{0}}
#define PTHREAD_COND_INITIALIZER {{0}}
#define PTHREAD_ONCE_INIT {{0}}
#define PTHREAD_RWLOCK_INITIALIZER {0x2DA8B3B4, {0}}

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

int pthread_rwlock_init(pthread_rwlock_t *, const pthread_rwlockattr_t *);
int pthread_rwlock_destroy(pthread_rwlock_t *);
int pthread_rwlock_rdlock(pthread_rwlock_t *);
int pthread_rwlock_wrlock(pthread_rwlock_t *);
int pthread_rwlock_tryrdlock(pthread_rwlock_t *);
int pthread_rwlock_trywrlock(pthread_rwlock_t *);
int pthread_rwlock_unlock(pthread_rwlock_t *);

int pthread_key_create(pthread_key_t *, void (*)(void *));
int pthread_key_delete(pthread_key_t);
void *pthread_getspecific(pthread_key_t);
int pthread_setspecific(pthread_key_t, const void *);

#ifdef __cplusplus
}
#endif

#endif
