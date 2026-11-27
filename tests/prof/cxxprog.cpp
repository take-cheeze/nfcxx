/* A C++ program for `nfcxx --profile`: a recursive free function fib (fib(10) makes 177 calls of fib), a class with a
 * method called from main, and one allocation of 100 bytes freed at the end. The profile has three sites: main, fib and
 * the method. */
#include <cstdio>
#include <cstdlib>

__attribute__((noinline)) int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

class Counter {
 public:
  __attribute__((noinline)) int twice(int v) const { return 2 * v; }
};

int main() {
  Counter c;
  void *block = std::malloc(100);
  std::printf("%d\n", c.twice(fib(10)));
  std::free(block);
  return 0;
}
