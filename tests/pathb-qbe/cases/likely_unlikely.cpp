// [[likely]] and [[unlikely]] on the arms of an if: the results are the same whichever way the hints point, and QBE puts
// the likely arm right after the test (the unlikely one out of line): the likely call comes first in the assembly.
// EXPECT: 0
// ASM-ORDER: _Z15f_then_unlikelyi hot cold
// ASM-ORDER: _Z13f_then_likelyi hot cold
// ASM-ORDER: _Z15f_else_unlikelyi hot cold
// ASM-ORDER: _Z13f_else_likelyi hot cold
// ASM-ORDER: _Z7f_blocki hot cold
// ASM-ORDER: _Z9f_nested1i hot cold
extern "C" {
__attribute__((noinline)) int hot(int x) { return x + 1; }
__attribute__((noinline)) int cold(int x) { return x - 1; }
}
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

int f_then_unlikely(int x) { if (x <= 0) [[unlikely]] return cold(x); return hot(x); }
int f_then_likely(int x) { if (x > 0) [[likely]] return hot(x); return cold(x); }
int f_else_unlikely(int x) { if (x > 0) return hot(x); else [[unlikely]] return cold(x); }
int f_else_likely(int x) { if (x <= 0) return cold(x); else [[likely]] return hot(x); }
int f_block(int x) {
  if (x > 0) [[likely]] { x = hot(x); } else [[unlikely]] { x = cold(x); }
  return x;
}
int f_nested1(int x) {
  if (x > 0) { [[likely]] x = hot(x); } else { x = cold(x); }
  return x;
}
// no hint, and a hint on a statement that is not an arm: nothing changes
int f_plain(int x) { if (x > 0) return hot(x); return cold(x); }
int f_loop(int n) {
  int s = 0;
  for (int i = 0; i < n; i++) {
    if (i % 3 == 0) [[unlikely]] s += 2;
    else [[likely]] s += 1;
  }
  return s;
}

int main() {
  for (int x = -3; x <= 3; x++) {
    int want = x > 0 ? x + 1 : x - 1;
    CHECK(f_then_unlikely(x) == want);
    CHECK(f_then_likely(x) == want);
    CHECK(f_else_unlikely(x) == want);
    CHECK(f_else_likely(x) == want);
    CHECK(f_block(x) == want);
    CHECK(f_nested1(x) == want);
    CHECK(f_plain(x) == want);
  }
  CHECK(f_loop(9) == 3 * 2 + 6 * 1);
  return bad;
}
