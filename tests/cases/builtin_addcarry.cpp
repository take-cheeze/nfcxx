// EXPECT: 0
// __builtin_ia32_addcarryx_u32/u64 and __builtin_ia32_sbb_u32/u64 (ADC and SBB): the carry in, the wrapped
// result through the pointer, the carry out. {fmt}'s uint128_fallback::operator+= is an operator on a struct of two
// uint64_t that adds with it (Path B used to refuse it: "unsupported builtin ia32_addcarryx_u64").
#include <stdint.h>
#if defined(__x86_64__)  // the intrinsics are x86 only

struct U128 {
  uint64_t lo_, hi_;
  U128 &operator+=(uint64_t n) noexcept {
    unsigned long long result;
    unsigned char carry = __builtin_ia32_addcarryx_u64(0, lo_, n, &result);
    lo_ = result;
    hi_ += carry;
    return *this;
  }
};

__attribute__((noinline)) unsigned char add64(unsigned char c, uint64_t a, uint64_t b, uint64_t *r) {
  unsigned long long o;
  unsigned char k = __builtin_ia32_addcarryx_u64(c, a, b, &o);
  *r = o;
  return k;
}
__attribute__((noinline)) unsigned char sub64(unsigned char c, uint64_t a, uint64_t b, uint64_t *r) {
  unsigned long long o;
  unsigned char k = __builtin_ia32_sbb_u64(c, a, b, &o);
  *r = o;
  return k;
}
__attribute__((noinline)) unsigned char add32(unsigned char c, unsigned a, unsigned b, unsigned *r) {
  return __builtin_ia32_addcarryx_u32(c, a, b, r);
}
__attribute__((noinline)) unsigned char sub32(unsigned char c, unsigned a, unsigned b, unsigned *r) {
  return __builtin_ia32_sbb_u32(c, a, b, r);
}

int main() {
  int bad = 0;
  uint64_t r;
  unsigned s;
  const uint64_t M = ~0ull;
  // 64-bit add: no carry, carry from the add, carry only from the carry in, both
  bad += !(add64(0, 1, 2, &r) == 0 && r == 3);
  bad += !(add64(1, 1, 2, &r) == 0 && r == 4);
  bad += !(add64(0, M, 1, &r) == 1 && r == 0);
  bad += !(add64(1, M, 0, &r) == 1 && r == 0);
  bad += !(add64(1, M, M, &r) == 1 && r == M);
  bad += !(add64(7, 5, 5, &r) == 0 && r == 11);   // any nonzero carry in counts as 1
  // 64-bit subtract
  bad += !(sub64(0, 5, 3, &r) == 0 && r == 2);
  bad += !(sub64(1, 5, 3, &r) == 0 && r == 1);
  bad += !(sub64(0, 3, 5, &r) == 1 && r == M - 1);
  bad += !(sub64(1, 5, 5, &r) == 1 && r == M);
  bad += !(sub64(1, 0, M, &r) == 1 && r == 0);
  // 32-bit
  bad += !(add32(0, 0xffffffffu, 1, &s) == 1 && s == 0);
  bad += !(add32(1, 0xffffffffu, 0, &s) == 1 && s == 0);
  bad += !(add32(1, 1, 1, &s) == 0 && s == 3);
  bad += !(sub32(0, 0, 1, &s) == 1 && s == 0xffffffffu);
  bad += !(sub32(1, 5, 4, &s) == 0 && s == 0);
  // the struct operator: a carry out of the low word reaches the high word
  U128 u = {M, 0};
  u += 1;
  bad += !(u.lo_ == 0 && u.hi_ == 1);
  u += M;
  bad += !(u.lo_ == M && u.hi_ == 1);
  u += 2;
  bad += !(u.lo_ == 1 && u.hi_ == 2);
  return bad;
}
#else
int main() { return 0; }
#endif
