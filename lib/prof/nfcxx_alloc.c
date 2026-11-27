/* Allocation counts for the profiler (docs/notes/profiler.md). Under --profile the program defines malloc, calloc, realloc
 * and free itself. Each one counts the call and forwards it to glibc's __libc_malloc, __libc_calloc, __libc_realloc and
 * __libc_free (exported by glibc). Because libc calls malloc through the PLT, the definitions here take over the calls
 * libc makes too (fopen's FILE and buffer, strdup, ...), so those allocations are counted in the site of the call that
 * made them. The counts are totals for the run (allocations, bytes requested and frees), and each thread also adds them to
 * the row of its current site (nfcxx_alloc_cur, nfcxx_prof.c). Without this file the counters stay at zero.
 *
 * The wrappers never allocate and never lock: they are called from malloc's own callers, possibly before the profiler's
 * constructor has run or from a thread it does not know. The per-site part is a plain increment of the calling thread's own
 * row. */
#define _GNU_SOURCE 1

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "nfcxx_alloc.h"

#define NOINSTR __attribute__((no_instrument_function))

/* A dynamic link defines the four names (they take over libc's PLT calls). The static variant (nfcxx_alloc_wrap.c, which
 * defines NFCXX_ALLOC_WRAP) defines __wrap_ names instead, for -Wl,--wrap: a static libc.a would clash with the plain names.
 * Both forward to __libc_*, which both links have. */
#ifdef NFCXX_ALLOC_WRAP
#define ENTRY(name) __wrap_##name
#else
#define ENTRY(name) name
#endif

static uint64_t g_allocs = 0, g_alloc_bytes = 0, g_frees = 0;

/* glibc's allocator, exported under these names (the public malloc, calloc, realloc and free are the ones defined below) */
void *__libc_malloc(size_t n);
void *__libc_calloc(size_t n, size_t m);
void *__libc_realloc(void *p, size_t n);
void __libc_free(void *p);

NOINSTR static void count_alloc(size_t n) {
  nfcxx_site_count *c = nfcxx_alloc_cur;
  __atomic_fetch_add(&g_allocs, 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&g_alloc_bytes, (uint64_t)n, __ATOMIC_RELAXED);
  if (c != NULL) {
    c->allocs++;
    c->bytes += (uint64_t)n;
  }
}

NOINSTR static void count_free(void) {
  nfcxx_site_count *c = nfcxx_alloc_cur;
  __atomic_fetch_add(&g_frees, 1, __ATOMIC_RELAXED);
  if (c != NULL) c->frees++;
}

NOINSTR void *ENTRY(malloc)(size_t n) {
  void *p = __libc_malloc(n);
  if (p != NULL) count_alloc(n);
  return p;
}

NOINSTR void *ENTRY(calloc)(size_t n, size_t m) {
  void *p = __libc_calloc(n, m);
  if (p != NULL) count_alloc(n * m);
  return p;
}

NOINSTR void *ENTRY(realloc)(void *p, size_t n) {
  void *q = __libc_realloc(p, n);
  if (q != NULL) count_alloc(n);
  if (q != NULL && p != NULL) count_free();
  return q;
}

NOINSTR void ENTRY(free)(void *p) {
  if (p != NULL) count_free();
  __libc_free(p);
}

void nfcxx_alloc_counts(uint64_t *allocs, uint64_t *bytes, uint64_t *frees) {
  *allocs = __atomic_load_n(&g_allocs, __ATOMIC_RELAXED);
  *bytes = __atomic_load_n(&g_alloc_bytes, __ATOMIC_RELAXED);
  *frees = __atomic_load_n(&g_frees, __ATOMIC_RELAXED);
}
