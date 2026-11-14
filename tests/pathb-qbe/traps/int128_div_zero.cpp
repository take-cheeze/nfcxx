// __int128 division by a zero divisor known only at run time: libgcc's __divti3 divides with divq and dies with SIGFPE, as
// the same program built by gcc does (gcc -O0 and the gcc backend give 136). Path B calls the same helper, so it dies the
// same way. (A literal zero divisor is different: gcc folds it into ud2, SIGILL, at -O2. The gcc backend is not compared.)
// TRAP-EXIT: 136
// TRAP-SKIP-AARCH64: aarch64 hardware does not trap a division by zero: libgcc's __divti3 returns 0 there, and gcc gives 0 too
typedef __int128 i128;

static volatile i128 zero = 0;

int main() {
  i128 n = 12345;
  i128 q = n / zero;   // SIGILL here
  return (int)q;
}
