// Emitter probe (not a runnable case): the counted int16 wrapping-add loop that
// scripts/pathb-hvx-emit.rb vectorizes to a vaddh main loop plus a scalar tail.
// tests/pathb-hvx/cases/add_i16/main.c drives it; exit 67 matches tests/cases/hvx_add_i16.cpp.
__attribute__((noinline)) void add_i16(short *dst, const short *a, const short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)(a[i] + b[i]);
}
