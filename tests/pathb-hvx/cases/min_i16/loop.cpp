// Emitter probe (not a runnable case): the counted int16 min-against-zero loop.
__attribute__((noinline)) void min_i16(short *dst, const short *a, int n) {
  for (int i = 0; i < n; ++i) dst[i] = a[i] < 0 ? a[i] : 0;
}
