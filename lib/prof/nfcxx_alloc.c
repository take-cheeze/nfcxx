/* Allocation counts for the profiler (docs/notes/profiler.md). Under --profile the link wraps malloc, calloc, realloc and free
 * (-Wl,--wrap), so every allocation of the program and of the libraries it calls passes through here. The counts are totals
 * for the run: allocations, bytes requested and frees. The runtime's own buffers are counted too; they are a few KB.
 * Without the wrap the counters stay at zero. */
#define _GNU_SOURCE 1

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "nfcxx_alloc.h"

static uint64_t g_allocs = 0, g_alloc_bytes = 0, g_frees = 0;

void *__real_malloc(size_t n);
void *__real_calloc(size_t n, size_t m);
void *__real_realloc(void *p, size_t n);
void __real_free(void *p);

static void count_alloc(size_t n) {
  __atomic_fetch_add(&g_allocs, 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&g_alloc_bytes, (uint64_t)n, __ATOMIC_RELAXED);
}

void *__wrap_malloc(size_t n) {
  void *p = __real_malloc(n);
  if (p != NULL) count_alloc(n);
  return p;
}

void *__wrap_calloc(size_t n, size_t m) {
  void *p = __real_calloc(n, m);
  if (p != NULL) count_alloc(n * m);
  return p;
}

void *__wrap_realloc(void *p, size_t n) {
  void *q = __real_realloc(p, n);
  if (q != NULL) count_alloc(n);
  if (q != NULL && p != NULL) __atomic_fetch_add(&g_frees, 1, __ATOMIC_RELAXED);
  return q;
}

void __wrap_free(void *p) {
  if (p != NULL) __atomic_fetch_add(&g_frees, 1, __ATOMIC_RELAXED);
  __real_free(p);
}

void nfcxx_alloc_counts(uint64_t *allocs, uint64_t *bytes, uint64_t *frees) {
  *allocs = __atomic_load_n(&g_allocs, __ATOMIC_RELAXED);
  *bytes = __atomic_load_n(&g_alloc_bytes, __ATOMIC_RELAXED);
  *frees = __atomic_load_n(&g_frees, __ATOMIC_RELAXED);
}
