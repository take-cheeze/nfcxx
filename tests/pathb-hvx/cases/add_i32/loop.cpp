// Emitter probe (not a runnable case): the counted int32 wrapping-add loop that
// scripts/pathb-hvx-emit.rb vectorizes to a vaddw vector main loop plus a scalar
// tail. tests/pathb-hvx/cases/add_i32/main.c drives it.
__attribute__((noinline)) void add_i32(int *dst, const int *a, const int *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = a[i] + b[i];
}
