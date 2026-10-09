// EXPECT: 94
// Calls: many arguments (some on the stack), struct results and struct arguments by value (padding included),
// recursion, a call through a function pointer, and a member function.
struct Big { long a, b, c; };
struct Mix { char c; double d; short s; };
__attribute__((noinline)) long many(int a, int b, int c, int d, int e, int f, int g, int h, long i, double x) {
  return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + i + (long)x;
}
__attribute__((noinline)) Big make(long x) { Big b{x, x * 2, x * 3}; return b; }
__attribute__((noinline)) long sumbig(Big v) { return v.a + v.b + v.c; }
__attribute__((noinline)) Mix mix(char c) { Mix m{c, 1.5, 7}; return m; }
int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
struct Acc { int v; int add(int x) { v += x; return v; } };
int apply(int (*f)(int), int x) { return f(x); }
int twice(int x) { return 2 * x; }
int main() {
  long r = many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10.0);
  Big b = make(4);
  long s = sumbig(b);
  Mix m = mix('A');
  int ok = m.c == 'A' && m.d == 1.5 && m.s == 7;
  Acc acc{1};
  int x = acc.add(4);
  return (int)(r + s + ok + fib(10) + apply(twice, 21) + x) & 255;
}
