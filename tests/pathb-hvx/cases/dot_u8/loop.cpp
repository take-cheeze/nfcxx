// Emitter probe (not a runnable case): uint8 dot-product reduction that
// scripts/pathb-hvx-emit.rb should lower to a vrmpyubv main loop plus a scalar
// tail. tests/pathb-hvx/cases/dot_u8/main.c drives it.
__attribute__((noinline)) int dot_u8(const unsigned char *a, const unsigned char *b, int n) {
  int sum = 0;
  for (int i = 0; i < n; ++i) sum += (int)a[i] * (int)b[i];
  return sum;
}
