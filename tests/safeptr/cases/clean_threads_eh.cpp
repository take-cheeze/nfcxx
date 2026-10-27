// Escaping locals in frames that a C++ exception leaves (EDG's longjmp: the frames never return), recursion, realloc,
// and threads with their own stacks: nothing is reported, and the frames that were left are released.
// EXPECT: 0
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <vector>
static int fill(int *p, int n) { for (int i = 0; i < n; i++) p[i] = i; return p[n - 1]; }
static int thrower(int depth) {
  int local[8];
  fill(local, 8);
  if (depth == 0) throw std::runtime_error("bottom");
  return thrower(depth - 1) + local[7];
}
static int recurse(int n) {
  int a[4];
  fill(a, 4);
  return n == 0 ? a[3] : recurse(n - 1) + a[0];
}
int main() {
  for (int round = 0; round < 100; round++) {
    try { thrower(10); return 1; } catch (const std::exception &) {}
    int after[16];
    if (fill(after, 16) != 15) return 2;   // the frames the exception left must not shadow these slots
  }
  if (recurse(500) != 3) return 3;
  char *p = static_cast<char *>(std::malloc(4));
  std::memcpy(p, "abc", 4);
  for (int n = 8; n < 4096; n *= 2) {
    p = static_cast<char *>(std::realloc(p, n));
    if (std::strcmp(p, "abc") != 0) return 4;
    std::memset(p + 4, 'x', n - 5);
    p[n - 1] = 0;
    p[3] = 0;
  }
  std::free(p);
  std::vector<std::thread> ts;
  std::vector<long> out(4);
  for (int t = 0; t < 4; t++)
    ts.emplace_back([t, &out] {
      long s = 0;
      for (int i = 0; i < 2000; i++) { std::vector<int> v(i % 50 + 1, t); int buf[8]; s += fill(buf, 8) + v.back(); }
      out[t] = s;
    });
  for (auto &th : ts) th.join();
  for (int t = 0; t < 4; t++) if (out[t] != 2000L * (7 + t)) return 5;
  return 0;
}
