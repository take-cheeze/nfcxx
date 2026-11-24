// EXPECT: 56
// IR-OPT: --hoist-pure
// Pure call hoisting (--hoist-pure, scripts/pathb-ir-opt.rb). weigh reads only its arguments and the global data, and the
// loop writes nothing, so weigh is computed once per entry to the loop. Unhoisted it is 2^35 multiply-adds, more than the
// run-time limit; hoisted it is one call. (A loop with an impure call that writes other memory is in tests/bench/backend:
// k_float's saxpy writes c while dot reads a and b.)
static long data[1 << 16];
__attribute__((noinline)) long weigh(const long* p, int n) {
  long s = 0;
  for (int i = 0; i < n; i++) s += p[i] * (i + 1);
  return s;
}
__attribute__((noinline)) long run(int rounds) {
  long acc = 0;
  for (int r = 0; r < rounds; r++) acc += weigh(data, 1 << 16);
  return acc;
}
int main() {
  for (int i = 0; i < (1 << 16); i++) data[i] = i % 13;
  long acc = run(1 << 19);
  return (int)((acc >> 16) & 255);
}
