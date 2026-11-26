/* count_alloc: the heap counters of tests/mrbbc/lower/measure.sh. Linked with -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,
 * --wrap=free, it counts the runtime's heap use (the calls the program's objects make, not libc's own) and prints at exit:
 *   mrbbc-alloc: total BYTES calls N peak BYTES
 * total is every byte requested, peak the most live at once (malloc_usable_size of each block). C99 with glibc. */
#define _GNU_SOURCE
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>

void *__real_malloc(size_t n);
void *__real_calloc(size_t n, size_t m);
void *__real_realloc(void *p, size_t n);
void __real_free(void *p);

static unsigned long long total, calls, live, peak;
static int registered;

static void report(void) { fprintf(stderr, "mrbbc-alloc: total %llu calls %llu peak %llu\n", total, calls, peak); }

static void count(void *p, size_t n) {
  if (!registered) {
    registered = 1;
    atexit(report);
  }
  if (p == NULL) return;
  total += n;
  calls++;
  live += malloc_usable_size(p);
  if (live > peak) peak = live;
}

void *__wrap_malloc(size_t n) {
  void *p = __real_malloc(n);
  count(p, n);
  return p;
}

void *__wrap_calloc(size_t n, size_t m) {
  void *p = __real_calloc(n, m);
  count(p, n * m);
  return p;
}

void *__wrap_realloc(void *p, size_t n) {
  void *q;
  if (p != NULL) live -= malloc_usable_size(p);
  q = __real_realloc(p, n);
  count(q, n);
  return q;
}

void __wrap_free(void *p) {
  if (p != NULL) live -= malloc_usable_size(p);
  __real_free(p);
}
