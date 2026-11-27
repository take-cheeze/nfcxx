/* Prints the machine probe and checks its sanity (see lib/prof/nfcxx_machine.c).
 * Clock and bandwidth values are only warned about: VMs vary. */
#include "nfcxx_machine.h"

#include <stdio.h>

static int failures;

#define CHECK(cond, msg)                  \
  do {                                    \
    if (!(cond)) {                        \
      printf("FAIL: %s\n", msg);          \
      failures++;                         \
    }                                     \
  } while (0)

static int line_ok(uint32_t line) {
  return line == 0 || line == 32 || line == 64 || line == 128;
}

int main(void) {
  nfcxx_machine m;
  char text[2048];
  size_t n;

  if (nfcxx_machine_probe(&m) != 0) {
    printf("FAIL: nfcxx_machine_probe returned an error\n");
    return 1;
  }
  n = nfcxx_machine_format(&m, text, sizeof text);
  fputs(text, stdout);
  CHECK(n < sizeof text, "format output truncated");

  CHECK(m.ncpu_affinity >= 1, "ncpu_affinity < 1");
  CHECK(m.page_size >= 4096 && (m.page_size & (m.page_size - 1)) == 0,
        "page size is not a power of two >= 4096");
  CHECK(line_ok(m.l1d_line), "L1d line size is not 32, 64 or 128");
  CHECK(line_ok(m.l2_line), "L2 line size is not 32, 64 or 128");
  CHECK(line_ok(m.l3_line), "L3 line size is not 32, 64 or 128");

  if (m.clock_ghz < 0.3 || m.clock_ghz > 6.0)
    printf("warning: clock %.3f GHz outside 0.3..6.0 (VM or unmeasured)\n", m.clock_ghz);
  if (m.mem_bw_gbs <= 0)
    printf("warning: memory bandwidth not measured\n");

  if (failures) {
    printf("FAIL tests/prof/machine (%d checks)\n", failures);
    return 1;
  }
  printf("PASS tests/prof/machine\n");
  return 0;
}
