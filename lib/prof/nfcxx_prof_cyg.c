/* gcc's -finstrument-functions hooks for the profiler (docs/notes/profiler.md). The driver's --profile adds the flag to the C
 * compiles and links this file with lib/prof/nfcxx_prof.c. A site is the offset of the function from the start of the
 * executable image, so the runtime can name it (nfcxx_prof.c, resolve_name). The offset is unique within one binary. */
#include <stdint.h>

#include "nfcxx_prof.h"

#define NOINSTR __attribute__((no_instrument_function))

extern char __executable_start[] __attribute__((weak));

NOINSTR static uint32_t site_of(void *fn) {
  uintptr_t base = (uintptr_t)__executable_start;
  return (uint32_t)((uintptr_t)fn - base);
}

NOINSTR void __cyg_profile_func_enter(void *fn, void *call_site) {
  (void)call_site;
  __nfcxx_prof_enter(site_of(fn));
}

NOINSTR void __cyg_profile_func_exit(void *fn, void *call_site) {
  (void)call_site;
  __nfcxx_prof_exit(site_of(fn));
}

/* The Path B hooks (scripts/pathb-ssa-qbe.rb, --profile): the same events, named by the function's address. */
NOINSTR void __nfcxx_prof_enter_addr(void *fn) { __nfcxx_prof_enter(site_of(fn)); }
NOINSTR void __nfcxx_prof_exit_addr(void *fn) { __nfcxx_prof_exit(site_of(fn)); }
