/* Allocation totals of the run (lib/prof/nfcxx_alloc.c). Zero unless the program is linked with the malloc wrappers. */
#ifndef NFCXX_ALLOC_H
#define NFCXX_ALLOC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void nfcxx_alloc_counts(uint64_t *allocs, uint64_t *bytes, uint64_t *frees);

#ifdef __cplusplus
}
#endif

#endif
