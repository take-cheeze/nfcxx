// Path B: structs passed and returned by value follow the C calling convention (System V x86-64), so that they agree
// with code Path B did not compile. libc's div, ldiv and lldiv return two-int and two-long structs in registers;
// libstdc++'s hashtable policy returns a std::pair<bool, size_t> that way (an unordered_set insert needs it).
// Functions defined here take and return every shape class: two ints (one register), two longs, two doubles
// (two SSE registers), a long and a double (one of each), a struct of three longs (memory), a float pair packed in
// one register, and one with padding; also through a function pointer and with more arguments than registers.
// EXPECT: 13
// STDOUT: same
#include <cstdio>
#include <cstdlib>

struct II { int a, b; };
struct LL { long a, b; };
struct DD { double a, b; };
struct LD { long a; double b; };
struct L3 { long a, b, c; };
struct FF { float a, b; };
struct Pad { int a; long b; };
struct One { char c; };

static II mk_ii(int a, int b) { II r = { a, b }; return r; }
static LL mk_ll(long a, long b) { LL r = { a, b }; return r; }
static DD mk_dd(double a, double b) { DD r = { a, b }; return r; }
static LD mk_ld(long a, double b) { LD r = { a, b }; return r; }
static L3 mk_l3(long a) { L3 r = { a, a * 2, a * 3 }; return r; }
static FF mk_ff(float a, float b) { FF r = { a, b }; return r; }
static Pad mk_pad(int a, long b) { Pad r = { a, b }; return r; }
static One mk_one(char c) { One r = { c }; return r; }

static long use_all(II a, LL b, DD c, LD d, L3 e, FF f, Pad g, One h, int x, int y, int z, long w)
{
  return a.a + a.b + b.a + b.b + (long)(c.a + c.b) + d.a + (long)d.b + e.a + e.b + e.c + (long)(f.a + f.b) + g.a + g.b +
         h.c + x + y + z + w;
}

static DD scale(DD v, double k) { DD r = { v.a * k, v.b * k }; return r; }

int main()
{
  int ok = 0;
  std::div_t d = std::div(17, 5);
  ok += d.quot == 3 && d.rem == 2;
  std::ldiv_t l = std::ldiv(-17L, 5L);
  ok += l.quot == -3 && l.rem == -2;
  std::lldiv_t ll = std::lldiv(1LL << 40, 1000LL);
  ok += ll.quot == 1099511627 && ll.rem == 776;

  ok += mk_ii(3, 4).b == 4;
  ok += mk_ll(1L << 40, 2).a == (1L << 40);
  ok += mk_dd(1.5, 2.5).b == 2.5;
  ok += mk_ld(7, 0.25).b == 0.25 && mk_ld(7, 0.25).a == 7;
  ok += mk_l3(5).c == 15;
  ok += mk_ff(1.5f, 2.5f).b == 2.5f;
  ok += mk_pad(9, 1L << 33).b == (1L << 33);
  ok += mk_one('x').c == 'x';

  long total = use_all(mk_ii(1, 2), mk_ll(3, 4), mk_dd(5.0, 6.0), mk_ld(7, 8.0), mk_l3(1), mk_ff(1.0f, 2.0f),
                       mk_pad(10, 11), mk_one(12), 13, 14, 15, 16);
  std::printf("total %ld\n", total);
  ok += total == 136;

  DD (*fp)(DD, double) = scale;
  DD s = fp(mk_dd(1.0, 2.0), 4.0);
  ok += s.a == 4.0 && s.b == 8.0;
  return ok;
}
