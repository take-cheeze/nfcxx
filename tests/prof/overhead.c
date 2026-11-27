/* Cost of one enter/exit pair of the profiler runtime (tests/prof/overhead.sh). The profile goes to NFCXX_PROFILE (set it to
 * /dev/null to measure the recording alone). Prints the nanoseconds per pair, measured by the monotonic clock around the loop.
 */
#include "nfcxx_prof.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double mono_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 2000000;
  long i;
  double t0, t1;
  t0 = mono_s();
  for (i = 0; i < n; i++) {
    __nfcxx_prof_enter(7);
    __nfcxx_prof_exit(7);
  }
  t1 = mono_s();
  printf("pairs=%ld enabled=%d ns_per_pair=%.1f\n", n, __nfcxx_prof_enabled(), (t1 - t0) * 1e9 / (double)n);
  return 0;
}
