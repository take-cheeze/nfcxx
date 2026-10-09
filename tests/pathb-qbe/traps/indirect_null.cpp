// Indirect call through a null function pointer must abort (nonnull before the call, stage 2 gap 9).
typedef int (*fn_t)(int);
__attribute__((noinline)) int apply(fn_t f, int x) { return f(x); }
int twice(int x) { return 2 * x; }
int main() {
  if (apply(twice, 4) != 8) return 1;   // a non-null pointer still works
  return apply(nullptr, 1);
}
