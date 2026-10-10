// __int128 and unsigned __int128 on Path B (docs/notes/pathb-int128.md): arithmetic, division, shifts, comparisons,
// conversions among integers, ++/--, compound assignment, globals, arrays, members, arguments and results. Every
// value is printed in hex, so the standard output must equal the gcc backend's byte for byte.
// STDOUT: same
// EXPECT: 0
#include <cstdio>
#include <cstring>

typedef __int128 i128;
typedef unsigned __int128 u128;

static void pr(const char *tag, u128 v) {
  std::printf("%s %016llx%016llx\n", tag, (unsigned long long)(v >> 64), (unsigned long long)v);
}
static void prs(const char *tag, i128 v) { pr(tag, (u128)v); }

static u128 mk(unsigned long hi, unsigned long lo) { return ((u128)hi << 64) | lo; }

// runtime values (volatile keeps gcc from folding anything)
static volatile unsigned long vhi = 0x0123456789abcdefUL, vlo = 0xfedcba9876543210UL;
static volatile long vsm = 3;
static volatile int vcount = 0;

i128 gs = -7;
u128 garr[3] = { 1, 2, (u128)-1 };
i128 gneg = -(i128)1 << 100;

struct Pair {
  i128 a;
  u128 b;
  int tag;
};
static Pair gp = { (i128)-3, (u128)5, 9 };

i128 addsub(i128 x, i128 y, int which) { return which ? x - y : x + y; }
u128 twice(u128 x) { return x + x; }
Pair swap_pair(Pair p) { Pair q = { p.b > 0 ? (i128)p.b : -p.a, (u128)p.a, p.tag + 1 }; return q; }

struct Base {
  virtual ~Base() {}
  virtual i128 get(i128 k) const { return k * 2; }
};
struct Derived : Base {
  i128 get(i128 k) const override { return -k - 1; }
};

int main() {
  u128 a = mk(vhi, vlo);
  u128 b = mk(0, 7);
  i128 sa = (i128)a;
  i128 sb = (i128)b;
  i128 small = 1000000007;

  pr("a", a);
  pr("b", b);
  pr("add", a + b);
  pr("sub", b - a);
  pr("mul", a * b);
  pr("neg", (u128)(-sa));
  pr("not", ~a);
  pr("and", a & mk(0xffff0000ffff0000UL, 0x00ff00ff00ff00ffUL));
  pr("or", a | mk(0x1, 0x2));
  pr("xor", a ^ mk(0x5a5a, 0xa5a5));
  prs("sdiv", sa / sb);
  prs("srem", sa % sb);
  prs("sdiv-neg", -sa / sb);
  prs("srem-neg", -sa % sb);
  prs("sdiv-negd", sa / -sb);
  prs("srem-negd", sa % -sb);
  pr("udiv", a / b);
  pr("urem", a % b);
  pr("udiv-big", a / mk(1, 0));
  pr("urem-big", a % mk(3, 5));
  prs("small", small * small * small);

  // shifts with runtime counts in range, signed and unsigned
  for (int k = 0; k < 128; k += 9) {
    long n = k + (vsm - 3);
    pr("shl", a << n);
    pr("shr", a >> n);
    prs("sshr", -sa >> n);
  }
  pr("shl64", b << 64);
  pr("shl127", b << 127);
  prs("sar127", (i128)(-1) >> 127);

  // comparisons (signed and unsigned orders differ for a and -a)
  std::printf("cmp %d %d %d %d %d %d\n", sa < sb, sa <= sb, sa > sb, sa >= sb, sa == sb, sa != sb);
  std::printf("ucmp %d %d %d %d %d %d\n", a < b, a <= b, a > b, a >= b, a == a, a != b);
  std::printf("mixed %d %d %d\n", (-sa) < (i128)0, (-sa) < (u128)1, (i128)-1 < (unsigned long)1);

  // increments, compound assignment
  i128 x = -1;
  std::printf("pre %d\n", (int)(++x == 0));
  i128 y = x++;
  prs("post-y", y);
  prs("post-x", x);
  x--;
  --x;
  prs("dec", x);
  x += 40;
  x -= 3;
  x *= 5;
  x /= 7;
  x %= 1000;
  prs("compound", x);
  x <<= 90;
  x >>= 3;
  x |= 0x0f;
  x &= ~(i128)0xff;
  x ^= 1;
  prs("bits", x);
  u128 ux = a;
  ux >>= (int)vsm * 3;
  pr("uxshr", ux);

  // conversions among integers
  std::printf("conv %lld %u %d %d %d\n", (long long)(sa), (unsigned)(a), (short)sb, (signed char)sa, (int)(sb - 1));
  std::printf("convu %llu %lu\n", (unsigned long long)(a), (unsigned long)(sa));
  std::printf("bool %d %d %d\n", (bool)(a), (bool)(b - 7), !(b - 7));
  prs("fromlong", (i128)-5L);
  pr("fromulong", (u128)(unsigned long)~0UL);
  prs("fromchar", (i128)(char)-1);
  prs("fromuchar", (i128)(unsigned char)255);
  prs("frombool", (i128)true);
  pr("fromint-neg", (u128)(i128)(-(int)vsm));
  pr("ternary", vsm > 2 ? a : b);
  std::printf("logic %d %d %d\n", (a && b) ? 1 : 0, (a && (u128)0) ? 1 : 0, (b || (u128)0) ? 1 : 0);

  // constants and limits
  pr("max-u", ~(u128)0);
  pr("max-s", (u128)((~(u128)0) >> 1));
  pr("min-s", (u128)((u128)1 << 127));
  prs("gneg", gneg);
  prs("gs", gs);
  pr("garr2", garr[2]);
  pr("garr0", garr[0] + garr[1]);

  // objects: members, arrays, pointers, copies
  Pair p = gp;
  p.a += 10;
  Pair q = swap_pair(p);
  prs("p.a", p.a);
  pr("p.b", p.b);
  prs("q.a", q.a);
  pr("q.b", q.b);
  std::printf("q.tag %d\n", q.tag);
  i128 arr[4];
  for (int i = 0; i < 4; i++) arr[i] = (i128)i * (i128)-1000000000000000000L;
  i128 total = 0;
  for (int i = 0; i < 4; i++) total += arr[i];
  prs("total", total);
  i128 *pa = &arr[2];
  prs("ptr", pa[1] - pa[0]);
  prs("idx", arr[(int)vsm]);
  u128 *pu = garr;
  pr("pu", *(pu + 1) + 1);

  // function arguments and results, function pointers, virtual calls
  prs("addsub", addsub(sa, sb, 0));
  prs("subf", addsub(sa, sb, 1));
  pr("twice", twice(a));
  i128 (*fp)(i128, i128, int) = addsub;
  prs("fp", fp(sb, sa, 0));
  Base *bp = new Derived();
  prs("virt", bp->get(sb));
  delete bp;
  Base *bq = new Base();
  prs("virt-base", bq->get(sb));
  delete bq;

  // bit-fields of 128-bit type
  struct Bits {
    unsigned __int128 u : 100;
    __int128 s : 70;
    int c : 3;
  };
  Bits bits = {};
  bits.u = mk(0xf, 0xffffffffffffffffUL);
  bits.s = -5;
  bits.c = -2;
  pr("bits.u", bits.u);
  prs("bits.s", bits.s);
  std::printf("bits.c %d\n", bits.c);
  bits.s += 1000;
  bits.u++;
  prs("bits.s2", bits.s);
  pr("bits.u2", bits.u);
  static Bits gbits = { mk(0x1, 0x2), (i128)-123456789, -1 };
  pr("gbits.u", gbits.u);
  prs("gbits.s", gbits.s);
  std::printf("gbits.c %d\n", gbits.c);

  std::printf("sizes %zu %zu\n", sizeof(i128), alignof(i128));
  return 0;
}
