// Emitter probe (not a runnable case): the counted int32 max-against-zero loop
// that scripts/pathb-hvx-emit.rb should vectorize to a vmaxw main loop plus a
// scalar tail (tinygrad hex_relu_kernel.py shape).
__attribute__((noinline)) void max_i32(int *dst, const int *a, int n) {
  for (int i = 0; i < n; ++i) dst[i] = a[i] > 0 ? a[i] : 0;
}
