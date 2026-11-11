// ASAN-SKIP: the asan mode refuses variable-length arrays
// EXPECT: 45
// A variable-length array: its size is a run-time value, and it lives until the function returns. The g++ result is 45.
static int fill(int n) {
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}
int main() { return fill(10); }
