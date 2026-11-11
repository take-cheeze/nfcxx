// EXPECT: 96
// ASAN-SKIP: the asan mode refuses variable-length arrays
// A variable-length array in a loop: each iteration's array is released at the end of the iteration. Without that, the
// 4000 arrays of 64 bytes (256 KB) would not fit the stack. Each round adds 15, so the sum is 60000, and the exit status is 60000 % 256 = 96.
static int sum_each(int rounds, int n) {
  int total = 0;
  for (int r = 0; r < rounds; r++) {
    int a[n];
    for (int i = 0; i < n; i++) a[i] = i + r;
    total += a[n - 1] - a[0];
  }
  return total;
}
int main() { return sum_each(4000, 16) % 256; }
