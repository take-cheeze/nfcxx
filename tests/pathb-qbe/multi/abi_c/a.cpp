// Path B calls code the host C compiler built, and is called by it: structs by value in registers (one or two, integer
// and SSE mixed), in memory, and as parameters beyond the registers. c.c is compiled by cc, a.cpp by the Path B pipeline.
// EXPECT: 9
#include <cstdio>

struct II { int a, b; };
struct LD { long a; double b; };
struct DD { double a, b; };
struct FFL { float a, b; long c; };
struct L4 { long a, b, c, d; };
struct Mbs { int count; union { unsigned wch; char wchb[4]; } value; };   // like glibc's __mbstate_t
struct Bits { unsigned lo : 5; unsigned hi : 20; int other; };

extern "C" {
II c_mk_ii(int a, int b);
LD c_mk_ld(long a, double b);
DD c_mk_dd(double a, double b);
FFL c_mk_ffl(float a, float b, long c);
L4 c_mk_l4(long a);
Mbs c_mk_mbs(int c, unsigned w);
Bits c_mk_bits(unsigned lo, unsigned hi, int other);
long c_sum_all(II a, LD b, DD c, FFL d, L4 e, Mbs f, Bits g, long k);
long c_call_back(void);

// called from C: take and return structs by value
II cpp_swap(II x) { II r = { x.b, x.a }; return r; }
LD cpp_ld(LD x, long k) { LD r = { x.a + k, x.b * 2 }; return r; }
L4 cpp_l4(L4 x) { L4 r = { x.d, x.c, x.b, x.a }; return r; }
}

int main()
{
  int ok = 0;
  II a = c_mk_ii(3, 4);
  ok += a.a == 3 && a.b == 4;
  LD b = c_mk_ld(5, 2.5);
  ok += b.a == 5 && b.b == 2.5;
  DD c = c_mk_dd(1.5, 6.5);
  ok += c.a == 1.5 && c.b == 6.5;
  FFL d = c_mk_ffl(1.0f, 2.0f, 40);
  ok += d.a == 1.0f && d.b == 2.0f && d.c == 40;
  L4 e = c_mk_l4(10);
  ok += e.a == 10 && e.d == 40;
  Mbs f = c_mk_mbs(7, 0x11223344u);
  ok += f.count == 7 && f.value.wch == 0x11223344u;
  Bits g = c_mk_bits(9, 1000, -5);
  ok += g.lo == 9 && g.hi == 1000 && g.other == -5;
  long s = c_sum_all(a, b, c, d, e, f, g, 1000);
  std::printf("sum %ld\n", s);
  // 3+4 + 5+2 + (1.5+6.5) + (1+2) + 40 + 100 + 7+0x11223344 + 9+1000-5 + 1000
  ok += s == 2176 + 0x11223344L;
  ok += c_call_back() == 1;
  return ok;
}
