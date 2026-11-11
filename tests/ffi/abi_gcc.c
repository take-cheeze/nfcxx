/* The gcc side of the ABI integration test (run.sh): the functions of abi.h as gcc calls them, printing their results. The
   host (abi_host.cpp) prints the same lines through nfcxx. */
#include <stddef.h>
#include <stdio.h>
#include "abi.h"
#include "abi_impl.c"  /* the definitions, after the header, as Ffi::load compiles them */

static Pt step_up(Pt p) { Pt r = {p.x + 1, p.y * 2}; return r; }
static int count_xy(Pt p) { return (int)(p.x + p.y); }
static int square(int x) { return x * x; }

int main(void) {
  printf("layout Pt %zu %zu %zu\n", sizeof(Pt), offsetof(Pt, x), offsetof(Pt, y));
  printf("layout Rec %zu %zu %zu %zu\n", sizeof(Rec), offsetof(Rec, n), offsetof(Rec, tag), offsetof(Rec, p));
  printf("layout Mixed %zu %zu %zu %zu\n", sizeof(Mixed), offsetof(Mixed, f), offsetof(Mixed, s), offsetof(Mixed, u));
  printf("ld_twice %.17Lg\n", ld_twice(1.25L));
  Rec r = rec_make(3, 1.5);
  printf("rec_make %d %d %.17g %.17g\n", r.n, r.tag, r.p.x, r.p.y);
  printf("rec_sum %.17g\n", rec_sum(r));
  Big b = big_make(7);
  printf("big_make %ld %ld %ld\n", b.a, b.b, b.c);
  Mixed m = mixed_make(2.5f);
  printf("mixed_make %.17g %d %d\n", m.f, m.s, m.u);
  Pt q = pt_step(step_up, (Pt){1.0, 3.0});
  printf("pt_step %.17g %.17g\n", q.x, q.y);
  printf("pt_count %d\n", pt_count(count_xy, 3));
  printf("sum_squares %d\n", sum_squares(square, 4));
  return 0;
}
