/* A C program for `nfcxx --profile`: fib(10) makes 177 calls of fib, and main is one more site call. */
#include <stdio.h>

__attribute__((noinline)) static int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

int main(void) {
  printf("%d\n", fib(10));
  return 0;
}
