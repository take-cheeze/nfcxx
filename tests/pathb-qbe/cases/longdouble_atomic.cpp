// std::atomic<long double> (docs/notes/pathb-longdouble.md): load, store, exchange and compare-exchange on a 16-byte object;
// libstdc++ calls __builtin_clear_padding on it first so that the compare ignores the six padding bytes (lowered to two
// stores of zero). The gcc backend cannot compile it (EDG's C output does not survive the generic __atomic builtins on a
// long double), so only EXPECT is checked.
// GCC: undefined
// EXPECT: 0
#include <atomic>
#include <cstdio>
#include <cstring>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main() {
  std::atomic<long double> at{1.5L};
  CHECK(at.load() == 1.5L);
  at = at.load() + 1;
  CHECK(at == 2.5L);
  long double expected = 2.5L, old = at.exchange(7.0L);
  CHECK(old == 2.5L && at.load() == 7.0L);
  CHECK(!at.compare_exchange_strong(expected, 9.0L) && expected == 7.0L && at.load() == 7.0L);
  CHECK(at.compare_exchange_strong(expected, 9.0L) && at.load() == 9.0L);
  at.store(-0.25L);
  CHECK(at.load() == -0.25L);
  // a value whose padding bytes hold garbage still compares equal to the stored one
  long double garbage = -0.25L;
  unsigned char* b = reinterpret_cast<unsigned char*>(&garbage);
  std::memset(b + 10, 0xA5, 6);
  long double e2 = garbage;
  CHECK(at.compare_exchange_strong(e2, 3.0L) && at.load() == 3.0L);
  std::printf("%d\n", fails);
  return fails;
}
