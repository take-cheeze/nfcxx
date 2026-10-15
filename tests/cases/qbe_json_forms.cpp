// EXPECT: 0
// What nlohmann/json and {fmt} (docs/notes/realworld.md) needed from scripts/qbe-prep.rb on the QBE path:
//  - `T x[N] __attribute__((__aligned__(A)))` on an object (not a struct member): cproc takes the GNU attribute
//    only on members, so it becomes `_Alignas(A)` (libstdc++'s std::_Sp_make_shared_tag, alignas on globals);
//  - __builtin_huge_val/isinf/ldexp/strcmp, which cproc does not know;
// Each check returns a bit; main returns the number of failed checks.
#include <cmath>
#include <limits>
#include <cstdint>
#include <cstring>

alignas(16) static char g_buf[40];
struct alignas(32) Over { char c[3]; };
static Over g_over;

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
  double nan_ = id(0.0) / id(0.0);  // runtime values: Path B refuses non-finite constants
  int bad = 0;
  double inf = id(1.0) / id(0.0);
  if (!__builtin_isinf(id(inf))) bad++;
  if (!__builtin_isinf(-id(inf))) bad++;
  if (__builtin_isinf(id(1.5))) bad++;
  if (!__builtin_isnan(id(nan_))) bad++;
  if (!(__builtin_huge_val() > 1e308)) bad++;
  if (__builtin_ldexp(id(3.0), 4) != 48.0) bad++;
  return bad;
}

static int check_misc() {
  int bad = 0;
  const char *s = "abc";
  if (__builtin_strcmp(s, "abc") != 0) bad++;
  if (__builtin_strcmp(s, "abd") >= 0) bad++;
  return bad;
}

int main() { return check_align() + check_math() + check_misc(); }
