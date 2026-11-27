/* Allocation counts of the run and per site (lib/prof/nfcxx_alloc.c, lib/prof/nfcxx_prof.c). Zero unless the program is
 * linked with the malloc wrappers. */
#ifndef NFCXX_ALLOC_H
#define NFCXX_ALLOC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The allocation counts of one site in one thread. The table of these is owned by nfcxx_prof.c; only the owning thread
 * writes a row, so the wrappers need no atomics for it. */
typedef struct nfcxx_site_count {
  uint32_t site;
  uint32_t used;
  uint64_t allocs;
  uint64_t bytes;
  uint64_t frees;
} nfcxx_site_count;

/* The row the calling thread's allocations are counted in: the site of its innermost open call, or the outside row when it
 * has none. NULL before the thread's first profiler event, so those allocations count in the run's totals only. Defined in
 * nfcxx_prof.c. The initial-exec model keeps the access free of calls (no __tls_get_addr, which can allocate). */
extern __thread nfcxx_site_count *nfcxx_alloc_cur __attribute__((tls_model("initial-exec")));

/* The run's totals. */
void nfcxx_alloc_counts(uint64_t *allocs, uint64_t *bytes, uint64_t *frees);

#ifdef __cplusplus
}
#endif

#endif
