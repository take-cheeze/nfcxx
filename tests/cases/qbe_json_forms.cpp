// EXPECT: 0
// What nlohmann/json and {fmt} (docs/notes/realworld.md) needed from scripts/qbe-prep.rb on the QBE path:
//  - `T x[N] __attribute__((__aligned__(A)))` on an object (not a struct member): cproc takes the GNU attribute
//    only on members, so it becomes `_Alignas(A)` (libstdc++'s std::_Sp_make_shared_tag, alignas on globals);
//  - __builtin_huge_val/nan/isfinite/isinf/signbit/bswap16/32/64/ldexp/strcmp, which cproc does not know;
//  - __atomic_thread_fence / __atomic_signal_fence (shared_ptr), a weak mfence stub in the assembly tail.
// Each check returns a bit; main returns the number of failed checks.
#include <cmath>
#include <limits>
#include <cstdint>
#include <cstring>

alignas(16) static char g_buf[40];
struct alignas(32) Over { char c[3]; };
static Over g_over;
static int g_val = 5;

static int check_align() {
  int bad = 0;
  if (reinterpret_cast<std::uintptr_t>(g_buf) % 16) bad++;
  if (reinterpret_cast<std::uintptr_t>(&g_over) % 32) bad++;
  alignas(64) static char local_static[7];
  if (reinterpret_cast<std::uintptr_t>(local_static) % 64) bad++;
  return bad;
}

__attribute__((noinline)) static double id(double x) { return x; }

static int check_math() {
  int bad = 0;
  double inf = std::numeric_limits<double>::infinity();
  if (!__builtin_isinf(id(inf))) bad++;
  if (!__builtin_isinf(-id(inf))) bad++;
  if (__builtin_isinf(id(1.5))) bad++;
  if (__builtin_isfinite(id(inf))) bad++;
  if (!__builtin_isfinite(id(1.5))) bad++;
  if (__builtin_isfinite(id(__builtin_nan("")))) bad++;
  if (!__builtin_isnan(id(__builtin_nan("")))) bad++;
  if (!__builtin_signbit(id(-0.0))) bad++;
  if (__builtin_signbit(id(2.0))) bad++;
  if (!(__builtin_huge_val() > 1e308)) bad++;
  if (__builtin_ldexp(id(3.0), 4) != 48.0) bad++;
  return bad;
}

static int check_bswap() {
  int bad = 0;
  volatile std::uint16_t a = 0x1234;
  volatile std::uint32_t b = 0x12345678u;
  volatile std::uint64_t c = 0x0102030405060708ull;
  if (__builtin_bswap16(a) != 0x3412) bad++;
  if (__builtin_bswap32(b) != 0x78563412u) bad++;
  if (__builtin_bswap64(c) != 0x0807060504030201ull) bad++;
  return bad;
}

static int check_misc() {
  int bad = 0;
  const char *s = "abc";
  if (__builtin_strcmp(s, "abc") != 0) bad++;
  if (__builtin_strcmp(s, "abd") >= 0) bad++;
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  g_val = 6;
  __atomic_thread_fence(__ATOMIC_RELEASE);
  if (g_val != 6) bad++;
  return bad;
}

int main() { return check_align() + check_math() + check_bswap() + check_misc(); }
