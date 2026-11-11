// EXPECT: 0
// PATHB-SKIP: Path B refuses the _Float32x type (pathb-cc); the QBE path is what this case checks.
// QBE path (scripts/qbe-prep): with _GNU_SOURCE, glibc's <stdlib.h> and <math.h> declare strtof32x and acosf32x with the
// types _Float32x (double on x86-64) and _Float64x (long double). qbe-prep used to drop their typedefs without mapping the
// uses, and cproc stopped with "declaration has no type specifier" (docs/notes/realworld.md). glibc is Linux-only: elsewhere
// the case only checks that the file compiles and exits 0.
#if defined(__linux__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdlib.h>
#include <math.h>

int main() {
  return (strtof32x("2.5", nullptr) == 2.5 && acosf32x(1.0) == 0.0) ? 0 : 1;
}
#else
int main() { return 0; }
#endif
