// EXPECT: 0
// GCC-SKIP: the host gcc (through nfcxx, at -O0) leaves __builtin_nansf128 undefined; plain g++ folds it. Path B is checked against EXPECT.
// std::numeric_limits<_Float128> reaches the NaN and infinity built-ins (nanf128, nansf128, huge_valf128). They are
// wrapped by __nfcxx_f128w_* in be/nfcxx_ldrt.c, so the IR has no unsupported call (tests/pathb-ir coverage gate).
#include <limits>
#include <cstring>

#if defined(__x86_64__) || defined(__aarch64__)
static unsigned long long hi_word(_Float128 v) {
  unsigned long long w[2];
  std::memcpy(w, &v, sizeof w);
  return w[1];
}

int main() {
  using L = std::numeric_limits<_Float128>;
  _Float128 q = L::quiet_NaN();
  _Float128 s = L::signaling_NaN();
  _Float128 i = L::infinity();
  // NaN is the one value that is not equal to itself; <cmath> is not included (its _Float128 overloads reach libm)
  if (!(q != q) || q == q) return 1;               // quiet NaN
  if (!(s != s)) return 2;                         // signaling NaN is a NaN
  if (!(i == L::infinity()) || i <= L::max()) return 3;   // +infinity is above the largest finite value
  if ((hi_word(q) & 0x0000800000000000ULL) == 0) return 4;   // the quiet bit is set on a quiet NaN
  if (hi_word(s) & 0x0000800000000000ULL) return 5;          // and clear on a signaling NaN
  return 0;
}
#else
int main() { return 0; }
#endif
