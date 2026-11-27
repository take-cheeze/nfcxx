/* nfcxx profiler runtime: timed enter/exit events per site (docs/notes/profiler.md).
 *
 * The profile is written only when the environment variable NFCXX_PROFILE names a file. The runtime's constructor reads it
 * before main runs and does nothing when it is unset or empty; the enter and exit calls then return at once.
 */
#ifndef NFCXX_PROF_H
#define NFCXX_PROF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Start and end of a profiled site. `site` is the compiler's number for the site (a stable id within the program). */
void __nfcxx_prof_enter(uint32_t site);
void __nfcxx_prof_exit(uint32_t site);

/* The same events, with the function's address as the site (gcc's hooks and the Path B hooks, nfcxx_prof_cyg.c). */
void __nfcxx_prof_enter_addr(void *fn);
void __nfcxx_prof_exit_addr(void *fn);

/* 1 when a profile is being written, 0 otherwise. */
int __nfcxx_prof_enabled(void);

#ifdef __cplusplus
}
#endif

#endif
