// Emitter probe (not a runnable case): the counted mixed-sign widening-multiply
// loop with the unsigned lane first, which scripts/pathb-hvx-emit.rb vectorizes
// to vmpyhus with swapped operands plus vasrwh plus a scalar tail.
// tests/pathb-hvx/cases/mul_us_i16/main.c drives it.
__attribute__((noinline)) void mul_us_i16(short *dst, const unsigned short *a, const short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)(((int)a[i] * b[i]) >> 4);
}
