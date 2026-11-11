// EXPECT: 9
// STDOUT: same
// A function that returns a const struct by value (libc++/STL allocator traits return `const T`): the struct is returned
// as the struct, the qualifier does not change its layout. Path B used to refuse the function ("returned aggregate
// (const (struct ...))"), so the whole translation unit was rejected.
#include <cstdio>
struct Pair {
  int a;
  long b;
};
const Pair make(int x) { return Pair{x, x * 2L}; }
int main() {
  const Pair p = make(3);
  const Pair q = make(1);
  std::printf("%d %ld %d %ld\n", p.a, p.b, q.a, q.b);
  return p.a + (int)p.b;
}
