// EXPECT: 0
// STDOUT: same
// __builtin_{add,sub,mul}_overflow with mixes of operand and result types (GCC semantics: the exact mathematical
// result, stored wrapped into the result type, the flag says it did not fit), the _p predicates, and the sized forms
// (__builtin_saddl_overflow ...). Differential: the hash of every (A, B, R, op) over boundary values is printed and must
// equal the gcc backend's, which computes the same thing with its own expansion.
#include <climits>
#include <cstdint>
#include <cstdio>

typedef unsigned long long u64;

template <class T> static void values(T *out, int &n) {
  n = 0;
  const long long base[] = {0, 1, 2, 3, 7, 100, 127, 128, 255, 256, 32767, 32768, 65535, 65536, 46340, 46341,
                            2147483647LL, 2147483648LL, 4294967295LL, 4294967296LL, 3037000499LL, 3037000500LL,
                            1LL << 62, (1LL << 62) + 1, LLONG_MAX, LLONG_MIN, LLONG_MIN + 1};
  for (long long b : base) {
    out[n++] = (T)b;
    out[n++] = (T)-b;
    out[n++] = (T)(b + 1);
    out[n++] = (T)(b - 1);
  }
  out[n++] = (T)~(T)0;
  out[n++] = (T)((T)~(T)0 >> 1);
  out[n++] = (T)((T)1 << (sizeof(T) * 8 - 1));
}

static u64 mix(u64 h, u64 v) { return (h ^ v) * 1099511628211ULL + 0x9e3779b97f4a7c15ULL; }

template <class A, class B, class R, int OP> static u64 run() {
  A as[256]; B bs[256];
  int na, nb;
  values(as, na);
  values(bs, nb);
  u64 h = 1469598103934665603ULL;
  for (int i = 0; i < na; i++)
    for (int j = 0; j < nb; j++) {
      R r = 0;
      bool o, p;
      if (OP == 0) { o = __builtin_add_overflow(as[i], bs[j], &r); p = __builtin_add_overflow_p(as[i], bs[j], (R)0); }
      else if (OP == 1) { o = __builtin_sub_overflow(as[i], bs[j], &r); p = __builtin_sub_overflow_p(as[i], bs[j], (R)0); }
      else { o = __builtin_mul_overflow(as[i], bs[j], &r); p = __builtin_mul_overflow_p(as[i], bs[j], (R)0); }
      if (o != p) return 1;
      h = mix(h, (u64)(long long)r);
      h = mix(h, o);
    }
  return h;
}

template <class A, class B, int OP> static void row(const char *an, const char *bn) {
  printf("%s %s op%d: s8 %llx u16 %llx s32 %llx u32 %llx s64 %llx u64 %llx\n", an, bn, OP,
         run<A, B, signed char, OP>(), run<A, B, unsigned short, OP>(), run<A, B, int, OP>(), run<A, B, unsigned, OP>(),
         run<A, B, long, OP>(), run<A, B, unsigned long, OP>());
}

template <class A, int OP> static void rows(const char *an) {
  row<A, signed char, OP>(an, "s8");
  row<A, unsigned, OP>(an, "u32");
  row<A, long, OP>(an, "s64");
  row<A, unsigned long, OP>(an, "u64");
}

template <int OP> static void all() {
  rows<signed char, OP>("s8");
  rows<unsigned short, OP>("u16");
  rows<int, OP>("s32");
  rows<unsigned, OP>("u32");
  rows<long, OP>("s64");
  rows<unsigned long, OP>("u64");
}

static int bit(bool cond, int n) { return cond ? 1 << n : 0; }

int main() {
  all<0>();
  all<1>();
  all<2>();
  int r = 0;
  // the sized built-ins
  int i = 0; long l = 0; long long ll = 0; unsigned u = 0; unsigned long ul = 0; unsigned long long ull = 0;
  bool o;
  o = __builtin_sadd_overflow(INT_MAX, 1, &i); r |= bit(o, 0) | bit(i == INT_MIN, 1);
  o = __builtin_saddl_overflow(LONG_MAX, 1L, &l); r |= bit(o, 2) | bit(l == LONG_MIN, 3);
  o = __builtin_saddll_overflow(LLONG_MIN, -1LL, &ll); r |= bit(o, 4) | bit(ll == LLONG_MAX, 5);
  o = __builtin_uadd_overflow(UINT_MAX, 2u, &u); r |= bit(o, 6) | bit(u == 1u, 7);
  o = __builtin_usubl_overflow(1ul, 2ul, &ul); r |= bit(o, 8) | bit(ul == ULONG_MAX, 9);
  o = __builtin_umulll_overflow(1ull << 63, 2ull, &ull); r |= bit(o, 10) | bit(ull == 0, 11);
  o = __builtin_smul_overflow(-65536, 32768, &i); r |= bit(!o, 12) | bit(i == INT_MIN, 13);
  o = __builtin_smulll_overflow(3037000500LL, 3037000500LL, &ll); r |= bit(o, 14);
  printf("sized %d\n", r);
  // the predicates fold in constant expressions
  static_assert(__builtin_mul_overflow_p(1 << 20, 1 << 20, (int)0), "folds");
  static_assert(!__builtin_add_overflow_p(1, 2, (int)0), "folds");
  return r == 0x7fff ? 0 : 1;
}
