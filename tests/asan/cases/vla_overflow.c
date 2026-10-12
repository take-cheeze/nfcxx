// ASAN: dynamic-stack-buffer-overflow
// ASAN-QBE: use-after-poison   (cproc's VLA: the redzones are poisoned at the declaration, asandynalloc)
// A variable-length array's element one past its end, in C input (C++ VLAs are EDG's runtime pool, see asan.md).
int sink(int *p, int i) { return p[i]; }
int main(int argc, char **argv) {
  int n = argc + 3;
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  return sink(a, n);
}
