// A subscript of a variable-length array is bounds-checked like the subscript of a fixed array: the index is compared with
// the run-time element count (the front end keeps it in a compiler variable) and an index past the end aborts. The
// in-range accesses before it do not trap.
// TRAP-IR: default
#include <stdio.h>
__attribute__((noinline)) int fill(int n, int bad_index) {
  int v[n];
  for (int i = 0; i < n; ++i) v[i] = i * 2;
  int s = 0;
  for (int i = 0; i < n; ++i) s += v[i];
  printf("sum %d\n", s);
  fflush(stdout);
  return v[bad_index];
}
int main() {
  fill(4, 3);
  return fill(4, 4);
}
