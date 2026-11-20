// Emitter probe (not a runnable case): the counted mixed-sign widening-multiply
// loop that scripts/pathb-hvx-emit.rb vectorizes to vmpyhus plus vasrwh plus a
// scalar tail. tests/pathb-hvx/cases/mul_su_i16/main.c drives it.
__attribute__((noinline)) void mul_su_i16(short *dst, const short *a, const unsigned short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)((a[i] * (int)b[i]) >> 4);
}
