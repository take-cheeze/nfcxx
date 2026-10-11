// EXPECT: 175
// for, while, break and continue, nested loops, and recursion.
int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main() {
  int total = 0;
  for (int i = 0; i < 20; i++) {
    if (i % 3 == 0) continue;
    if (i > 14) break;
    total += i;
  }
  int j = 0;
  while (j < 10) {
    j++;
    int k = 0;
    while (k < 10) {
      k++;
      if (k == j) break;
      total += 1;
    }
  }
  return (total + fib(10)) & 0xff;
}
