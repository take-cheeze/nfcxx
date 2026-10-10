// __float128 (_Float128) in Path B (docs/notes/pathb-float128.md): arithmetic, comparisons, conversions both ways (int,
// __int128, float, double, long double), constants, globals, members, arrays, arguments and results, the classification
// built-ins and the increment operators. Values are printed as their 128-bit patterns, so they are compared exactly with
// the gcc backend (gcc's soft-float, libgcc's __addtf3 and friends, on both sides).
// STDOUT: same
// EXPECT: 0
#include <cmath>
#include <cstdio>
#include <cstring>

typedef __float128 f128;
typedef __int128 i128;
typedef unsigned __int128 u128;

static void prq(const char *tag, f128 x) {
  unsigned long long w[2];
  std::memcpy(w, &x, sizeof w);
  std::printf("%s %016llx%016llx\n", tag, w[1], w[0]);
}
static void pri(const char *tag, long long v) { std::printf("%s %lld\n", tag, v); }
static void prb(const char *tag, bool b) { std::printf("%s %d\n", tag, (int)b); }
static void prw(const char *tag, u128 v) {
  std::printf("%s %016llx%016llx\n", tag, (unsigned long long)(v >> 64), (unsigned long long)v);
}
static void prd(const char *tag, double x) {
  unsigned long long u;
  std::memcpy(&u, &x, sizeof u);
  std::printf("%s d %016llx\n", tag, u);
}
static void prld(const char *tag, long double x) {
  unsigned char b[16];
  std::memset(b, 0, sizeof b);
  std::memcpy(b, &x, 10);
  std::printf("%s ld ", tag);
  for (int i = 9; i >= 0; i--) std::printf("%02x", b[i]);
  std::printf("\n");
}

// Opaque identity: the operands come from memory, so nothing is folded at compile time.
static volatile f128 vq = 1.25;
static volatile f128 vzero = 0;
static volatile double vd = 3.0;

__attribute__((noinline)) static f128 ident(f128 x) { return x; }
__attribute__((noinline)) static f128 mul3(f128 a, f128 b, f128 c) { return a * b * c; }
__attribute__((noinline)) static int cmp3(f128 a, f128 b, f128 c) { return (a < b) + 2 * (b <= c) + 4 * (c != a); }

struct Pair {
  f128 a;
  f128 b;
  int tag;
};

static f128 gtab[3] = {1.5, 2.25, -0.125};
static f128 gone = 1;
static Pair gpair = {4.5, -2, 7};

struct Base {
  virtual ~Base() {}
  virtual f128 scale(f128 x) const = 0;
};
struct Twice : Base {
  f128 k;
  explicit Twice(f128 v) : k(v) {}
  f128 scale(f128 x) const override { return x * 2 + k; }
};

static f128 apply(f128 (*fn)(f128), f128 x) { return fn(x); }

int main() {
  // constants (EDG's binary128 value, the same bits gcc gets)
  f128 c1 = (f128)0.1L;
  f128 c2 = (f128)1e300;
  f128 c3 = (f128)1e4000L;
  prq("c1", c1);
  prq("c2", c2);
  prq("c3", c3);
  prq("gtab1", gtab[2]);
  prq("gone", gone);
  prq("gpair", gpair.a);
  pri("gpair.tag", gpair.tag);

  // arithmetic on runtime values
  f128 x = vq;
  f128 y = ident(3.0);
  prq("add", x + y);
  prq("sub", x - y);
  prq("mul", x * y);
  prq("div", y / x);
  prq("neg", -x);
  prq("third", ident(1) / ident(3));
  prq("mul3", mul3(x, y, c1));
  prq("apply", apply(ident, x * 2));

  // compound assignments and increments
  f128 acc = x;
  acc += y;
  acc -= 0.5;
  acc *= 4;
  acc /= 3;
  prq("acc", acc);
  f128 inc = x;
  f128 old = inc++;
  prq("postinc.old", old);
  prq("postinc.new", inc);
  prq("preinc", ++inc);
  prq("predec", --inc);

  // comparisons (NaN and infinity from run-time operations)
  f128 nan = vzero / vzero;
  f128 inf = ident(1) / vzero;
  f128 ninf = -inf;
  prb("eq", x == y);
  prb("ne", x != y);
  prb("lt", x < y);
  prb("le", x <= x);
  prb("gt", y > x);
  prb("ge", x >= y);
  prb("nan==nan", nan == nan);
  prb("nan!=nan", nan != nan);
  prb("nan<1", nan < 1);
  prb("inf>max", inf > (f128)1e4000L);
  prb("ninf<0", ninf < 0);
  pri("cmp3", cmp3(x, y, c1));
  prb("nz", x);
  prb("!nz", !vzero);
  prb("and", x && y);
  prb("or", vzero || vzero);
  prq("cond", x > y ? x : y);

  // classification
  pri("isnan", __builtin_isnan(nan) != 0);
  pri("isinf", __builtin_isinf(inf) != 0);
  pri("isinf-neg", __builtin_isinf(ninf) != 0);
  pri("isfinite", __builtin_isfinite(x) != 0);
  pri("isnormal", __builtin_isnormal(x) != 0);
  pri("isnormal0", __builtin_isnormal(vzero) != 0);
  pri("signbit", __builtin_signbit(ninf) != 0);
  pri("signbit0", __builtin_signbit(-vzero) != 0);
  pri("fpclass", __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x));
  pri("fpclass-nan", __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, nan));
  pri("fpclass-zero", __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, vzero));
  pri("isgreater", __builtin_isgreater(y, x));
  pri("isunordered", __builtin_isunordered(nan, x));

  // conversions to integers (truncation toward zero)
  f128 m = (f128)-7.75;
  pri("int", (int)m);
  pri("ll", (long long)(x * 1000));
  pri("ll-neg", (long long)m);
  std::printf("uint %u\n", (unsigned)(x * 3));
  prw("i128", (u128)(i128)(x * (f128)1e15));
  prw("i128-neg", (u128)(i128)(-(f128)1e30));
  prw("u128", (u128)(x * (f128)1e30));

  // conversions from integers
  prq("from-int", (f128)-123456789);
  prq("from-ll", (f128)(long long)-1234567890123456789LL);
  prq("from-ull", (f128)(unsigned long long)18446744073709551615ULL);
  prq("from-i128", (f128)(((i128)1 << 100) + 12345));
  prq("from-u128", (f128)(((u128)1 << 127) + 3));

  // conversions among the floating types
  prq("from-double", (f128)vd);
  prq("from-float", (f128)(float)0.75f);
  prd("to-double", (double)(x * 1.5));
  prld("to-ld", (long double)(x * 1.5));
  prq("from-ld", (f128)(1.0L / 3));
  prq("ld-round", (f128)(long double)c1);
  std::printf("to-float %08x\n", [](float f) { unsigned u; std::memcpy(&u, &f, 4); return u; }((float)(x / 7)));

  // memory: arrays, members, unions of a 16-byte float with integers
  f128 arr[4];
  for (int i = 0; i < 4; i++) arr[i] = ident(i) * 0.5 + gtab[i % 3];
  for (int i = 0; i < 4; i++) prq("arr", arr[i]);
  Pair p = gpair;
  p.b = p.a * 2;
  prq("pair.b", p.b);
  pri("pair.tag", p.tag);
  f128 *pa = &arr[2];
  prq("ptr", *pa);
  pri("ptrdiff", pa - &arr[0]);

  // virtual call and a pointer to a member function returning _Float128
  Twice tw(ident(0.5));
  Base *b = &tw;
  prq("virt", b->scale(x));

  // the value of an assignment expression, and a comma
  f128 z;
  prq("assign", (z = x + y));
  prq("comma", (vzero, z * 2));
  return 0;
}
