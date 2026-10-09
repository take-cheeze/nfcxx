/* The C side of multi/abi_c: built by the host C compiler. */
struct II { int a, b; };
struct LD { long a; double b; };
struct DD { double a, b; };
struct FFL { float a, b; long c; };
struct L4 { long a, b, c, d; };
struct Mbs { int count; union { unsigned wch; char wchb[4]; } value; };
struct Bits { unsigned lo : 5; unsigned hi : 20; int other; };

struct II c_mk_ii(int a, int b) { struct II r = { a, b }; return r; }
struct LD c_mk_ld(long a, double b) { struct LD r = { a, b }; return r; }
struct DD c_mk_dd(double a, double b) { struct DD r = { a, b }; return r; }
struct FFL c_mk_ffl(float a, float b, long c) { struct FFL r = { a, b, c }; return r; }
struct L4 c_mk_l4(long a) { struct L4 r = { a, a * 2, a * 3, a * 4 }; return r; }
struct Mbs c_mk_mbs(int c, unsigned w) { struct Mbs r; r.count = c; r.value.wch = w; return r; }
struct Bits c_mk_bits(unsigned lo, unsigned hi, int other) { struct Bits r; r.lo = lo; r.hi = hi; r.other = other; return r; }

long c_sum_all(struct II a, struct LD b, struct DD c, struct FFL d, struct L4 e, struct Mbs f, struct Bits g, long k)
{
  return a.a + a.b + b.a + (long)b.b + (long)(c.a + c.b) + (long)(d.a + d.b) + d.c + e.a + e.b + e.c + e.d +
         f.count + f.value.wch + g.lo + g.hi + g.other + k;
}

struct II cpp_swap(struct II x);
struct LD cpp_ld(struct LD x, long k);
struct L4 cpp_l4(struct L4 x);

long c_call_back(void)
{
  struct II i = { 1, 2 };
  struct II j = cpp_swap(i);
  struct LD l = { 10, 1.5 };
  struct LD m = cpp_ld(l, 5);
  struct L4 q = { 1, 2, 3, 4 };
  struct L4 r = cpp_l4(q);
  return j.a == 2 && j.b == 1 && m.a == 15 && m.b == 3.0 && r.a == 4 && r.d == 1;
}
