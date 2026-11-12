// ASAN: dynamic-stack-buffer-overflow
// ASAN-PATHB: heap-buffer-overflow   (EDG lowers a C VLA to __vla_alloc: a malloc block under lib/asan/nfcxx_vla_asan.c)
// A variable-length array's element one past its end, in C input (C++ VLAs are EDG's runtime pool, see asan.md).
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **argv) {
  int n = argc + 3;
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  return sink(a, n);
}
