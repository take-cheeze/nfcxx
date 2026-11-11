// EXPECT: 55
// Direct calls, recursion, a void callee that writes through a pointer, a call through a function pointer, and
// a variadic call.
#include <stdio.h>
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static void bump(int *p, int by) { *p += by; }
static int twice(int v) { return 2 * v; }
int main(void) {
  int acc = 0;
  bump(&acc, fib(10));                   /* 55 */
  int (*f)(int) = twice;
  acc = f(acc) / 2;                      /* 55 */
  printf("acc=%d\n", acc);
  return acc;
}
