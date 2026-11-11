// CLEAN
// Functions that alloca, called again and again, then a function whose own objects reuse that stack: the redzones of the
// alloca blocks must be unpoisoned when the function returns (an early return, a loop of allocas, a return in the loop).
__attribute__((noinline)) int with_alloca(int n, int early) {
  char *p = (char *)__builtin_alloca(n);
  for (int i = 0; i < n; i++) p[i] = (char)i;
  if (early) return p[n - 1];
  char *q = (char *)__builtin_alloca(n + 3);
  for (int i = 0; i < n + 3; i++) q[i] = (char)(p[i % n] + 1);
  return q[n + 2];
}
__attribute__((noinline)) int in_loop(int rounds) {
  int s = 0;
  for (int i = 1; i <= rounds; i++) {
    char *p = (char *)__builtin_alloca(i * 3);
    for (int j = 0; j < i * 3; j++) p[j] = (char)j;
    s += p[i * 3 - 1];
    if (i == rounds / 2) return s;
  }
  return s;
}
__attribute__((noinline)) int reuse(int n) {
  int a[96];
  for (int i = 0; i < 96; i++) a[i] = i + n;
  int s = 0;
  for (int i = 0; i < 96; i++) s += a[i];
  return s;
}
int main() {
  int t = 0;
  for (int k = 1; k < 40; k++) {
    t += with_alloca(k + 5, k & 1) & 7;
    t += in_loop(k) & 7;
    t += reuse(k) & 7;
  }
  return t > 0 ? 0 : 1;
}
