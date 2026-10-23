// EXPECT: 0
// QBE path (scripts/qbe-prep.rb): with _GNU_SOURCE (the C++ driver defines it), glibc's <stdlib.h> and <math.h> declare strtof32x and acosf32x with the
// types _Float32x (double on x86-64) and _Float64x (long double). qbe-prep.rb used to drop their typedefs without mapping the
// uses, and cproc stopped with "declaration has no type specifier" (docs/notes/realworld.md).
#include <stdlib.h>
#include <math.h>

int main() {
  return (strtof32x("2.5", nullptr) == 2.5 && acosf32x(1.0) == 0.0) ? 0 : 1;
}
