// Built with -fsanitize=undefined: a program with no undefined behavior behaves exactly as without the checks, and agrees
// with the gcc backend. Values near the limits, unsigned wrap-around (not undefined), 64-bit products that fit,
// shifts of every legal count, division of the extremes, indexes at the ends of arrays, loops, switch, a VLA, recursion.
// SANITIZE: undefined
// EXPECT: 0
#include <climits>
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) long idl(long x) { return x; }
__attribute__((noinline)) unsigned idu(unsigned x) { return x; }

__attribute__((noinline)) int fact(int n) { return n <= 1 ? 1 : n * fact(n - 1); }

__attribute__((noinline)) int sum_vla(int n) {
  int a[n];
  for (int i = 0; i < n; i++) a[i] = i;
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}

__attribute__((noinline)) int classify(int x) {
  switch (x) {
    case 0: return 10;
    case 1: return 11;
    default: return x > 100 ? 1 : 2;
  }
}

int main() {
  CHECK(id(INT_MAX) - 1 == INT_MAX - 1);
  CHECK(id(INT_MIN) + 1 == INT_MIN + 1);
  CHECK(id(INT_MAX) + id(INT_MIN) == -1);
  CHECK(idu(UINT_MAX) + 1u == 0u);                 // unsigned wrap-around is defined
  CHECK(idu(0) - 1u == UINT_MAX);
  CHECK(idl(3037000499L) * idl(3037000499L) == 9223372030926249001L);   // fits in 64 bits
  CHECK(idl(-3037000499L) * idl(3037000499L) == -9223372030926249001L);
  CHECK(idl(LONG_MIN) * idl(1) == LONG_MIN);
  CHECK(idl(LONG_MAX) * idl(-1) == -LONG_MAX);
  CHECK(idl(0) * idl(LONG_MIN) == 0);
  CHECK(id(46340) * id(46340) == 2147395600);
  CHECK(id(INT_MIN) / id(1) == INT_MIN);
  CHECK(id(INT_MIN) % id(2) == 0);
  CHECK(id(-7) / id(2) == -3 && id(-7) % id(2) == -1);
  CHECK(-id(INT_MAX) == -INT_MAX);
  for (int s = 0; s < 31; s++) CHECK((id(1) << s) == (int)(1u << s) || s == 31);
  for (int s = 0; s < 32; s++) CHECK((idu(1) << s) == (1u << s));
  CHECK((id(-8) >> id(1)) == -4);
  int a[5] = {1, 2, 3, 4, 5};
  CHECK(a[id(0)] == 1 && a[id(4)] == 5);
  CHECK(fact(10) == 3628800);
  CHECK(sum_vla(100) == 4950);
  CHECK(classify(0) == 10 && classify(1) == 11 && classify(200) == 1 && classify(5) == 2);
  int i = INT_MAX - 3;
  for (; i < INT_MAX; i++) {}
  CHECK(i == INT_MAX);
  CHECK((int)id(2147483647.0) == INT_MAX);
  return bad;
}
