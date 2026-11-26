/* gcc's -finstrument-functions hooks for the profiler (docs/notes/profiler.md). The driver's --profile adds the flag to the C
 * compiles and links this file with lib/prof/nfcxx_prof.c. The site of a function is its address (the low 32 bits) for now;
 * the compiler will later write a string table that names each site. */
#include <stdint.h>

#include "nfcxx_prof.h"

#define NOINSTR __attribute__((no_instrument_function))

NOINSTR void __cyg_profile_func_enter(void *fn, void *call_site) {
  (void)call_site;
  __nfcxx_prof_enter((uint32_t)(uintptr_t)fn);
}

NOINSTR void __cyg_profile_func_exit(void *fn, void *call_site) {
  (void)call_site;
  __nfcxx_prof_exit((uint32_t)(uintptr_t)fn);
}
