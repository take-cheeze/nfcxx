// Emitter probe (not a runnable case): the counted int16 widening-multiply loop
// with a constant shift that scripts/pathb-hvx-emit.rb vectorizes to vmpyhv plus
// vasrwh plus a scalar tail. tests/pathb-hvx/cases/mul_i16/main.c drives it;
// exit 184 matches tests/cases/hvx_mul_i16.cpp.
__attribute__((noinline)) void mul_q4_i16(short *dst, const short *a, const short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)((a[i] * b[i]) >> 4);
}
