/* The C side of tests/pathb-ssa-qbe/byval/run.rb: calls the functions emitted from byval.ir with the C structs they
   correspond to (the System V x86-64 ABI is the reference), and checks each result. Prints "ok" when all hold. */
#include <stdio.h>

struct II { int a, b; };
struct LL { long a, b; };
struct DD { double a, b; };
struct LD { long a; double b; };
struct L3 { long a, b, c; };

struct II mk_ii(int, int);
struct LL mk_ll(long, long);
struct DD mk_dd(double, double);
struct LD mk_ld(long, double);
struct L3 mk_l3(long);
int sum_ii(struct II);
long sum_ll(struct LL, long);
double sum_dd(struct DD, double);
long sum_l3(struct L3);
int pass_ii(int, int);

static int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s\n", #c); fails++; } } while (0)

int main(void)
{
  struct II r = mk_ii(3, 4);
  CHECK(r.a == 3 && r.b == 4);
  CHECK(sum_ii(r) == 7);
  CHECK(pass_ii(-2, 9) == 7);

  struct LL l = mk_ll(10, 20);
  CHECK(l.a == 10 && l.b == 20);
  CHECK(sum_ll(l, 5) == 35);

  struct DD d = mk_dd(1.5, 2.25);
  CHECK(d.a == 1.5 && d.b == 2.25);
  CHECK(sum_dd(d, 0.25) == 4.0);

  struct LD ld = mk_ld(7, 8.5);
  CHECK(ld.a == 7 && ld.b == 8.5);

  struct L3 t = mk_l3(5);
  CHECK(t.a == 5 && t.b == 6 && t.c == 7);
  CHECK(sum_l3(t) == 12);

  printf("%s\n", fails ? "FAIL" : "ok");
  return fails != 0;
}
