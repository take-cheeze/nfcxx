/* A C program for `nfcxx --profile`: fib(10) makes 177 calls of fib, and main is one more site call. main also makes ten
 * allocations of 100 bytes and frees them, so the allocation counts of the profile are at least 10 and 1000 bytes. */
#include <stdio.h>
#include <stdlib.h>

__attribute__((noinline)) static int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

int main(void) {
  void *blocks[10];
  int i;
  for (i = 0; i < 10; i++) blocks[i] = malloc(100);
  printf("%d\n", fib(10));
  for (i = 0; i < 10; i++) free(blocks[i]);
  return 0;
}
