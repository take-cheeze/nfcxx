#include <stdio.h>
long sum_ints(int n, ...);
int main(void) {
  long a = sum_ints(3, 10, 20, 30);
  long b = sum_ints(0);
  long c = sum_ints(5, 1, 2, 3, 4, 5);
  printf("%ld %ld %ld\n", a, b, c);
  return a == 60 && b == 0 && c == 15 ? 0 : 1;
}
