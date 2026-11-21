// EXPECT: 0
// STDOUT: same
// The nothrow analysis of the exception tables (scripts/pathb-ssa-qbe.rb nothrow_callees, QBE's ehnothrow): a call of
// a callee that lets no exception out has no call site entry, and the calls around it share one entry. Each callee
// that can throw must keep its entry: one that throws through another static function, an indirect call, an
// __attribute__((weak)) definition (another object may replace it), and a noexcept function, which keeps its own
// exception inside (its catch) and is nothrow for its callers.
#include <cstdio>
#include <cstring>
struct D {
  const char *n;
  ~D() { std::printf("~%s\n", n); }
};
static int sum(int a, int b) { return a + b; }
__attribute__((noinline)) static void deep(int x) {
  if (x == 3) throw x;
}
__attribute__((noinline)) static int via(int x) {
  deep(x);
  return sum(x, 1);
}
__attribute__((noinline)) int guarded(int x) noexcept {
  try {
    deep(x);
  } catch (int e) {
    std::printf("guarded caught %d\n", e);
  }
  return x;
}
__attribute__((weak, noinline)) int replaceable(int x) {
  if (x == 5) throw x * 10;
  return x;
}
__attribute__((noinline)) static void indirect_throw(int x) {
  if (x == 7) throw x;
}
static void (*volatile fp)(int) = indirect_throw;

static int run(int x) {
  D d{"run"};
  char buf[16];
  std::memset(buf, 0, sizeof buf);
  int r = sum(x, 2);
  r += guarded(x);
  r += via(x);
  r += sum(r, x);
  r += replaceable(x);
  fp(x);
  r += sum(r, 1);
  return r;
}

int main() {
  int fails = 0;
  for (int x = 0; x < 9; x++) {
    try {
      std::printf("run(%d) = %d\n", x, run(x));
      if (x == 3 || x == 5 || x == 7) fails++;
    } catch (int e) {
      std::printf("caught %d\n", e);
      if (x != 3 && x != 5 && x != 7) fails++;
    }
  }
  return fails;
}
