// Emitter probe (not a runnable case): the mixed-sign uint8 dot-product
// reduction (u8 activations x i8 weights, the quantized inner-loop shape) that
// scripts/pathb-hvx-emit.rb lowers to a vrmpybusv_acc main loop plus a horizontal
// sum and a scalar tail. tests/pathb-hvx/cases/dot_su8/main.c drives it.
__attribute__((noinline)) int dot_su8(const unsigned char *a, const signed char *b, int n) {
  int sum = 0;
  for (int i = 0; i < n; ++i) sum += (int)a[i] * (int)b[i];
  return sum;
}
