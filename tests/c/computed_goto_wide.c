/* EXPECT: 0 */
// XFAIL-qbe: cproc has no computed goto (label addresses, goto *p); Path B lowers it (docs/notes/pathb-computed-goto.md)
/* GNU C computed goto in an interpreter loop with many opcodes (QuickJS's JS_CallInternal has about 250): a `goto *` after
   every opcode, a struct returned by value in each, and a void function with the same shape that ends without a return. Path B
   gives a function with 16 or more address-taken labels one shared dispatch switch (be/nfcxx_ir.c, ir_assigned_goto);
   one switch per `goto *` would be 24 x 24 cases here and about 60,000 edges in QuickJS. Self-checking: every value is what gcc
   produces. */
#include <stdio.h>

typedef struct { long a, b; } V;

static V mk(long x) { V v = { x, x * 2 }; return v; }
static long sum(V v) { return v.a + v.b; }

#define OPS(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) X(8) X(9) X(10) X(11) \
               X(12) X(13) X(14) X(15) X(16) X(17) X(18) X(19) X(20) X(21) X(22) X(23)
#define TAB(n) &&L##n,
#define CASE(n) L##n: acc += sum(mk(n + 1)) * (n % 3 + 1); DISPATCH();

static long run(const unsigned char *pc)
{
  static void *const tab[] = { OPS(TAB) &&L_STOP };
  long acc = 0;
#define DISPATCH() goto *tab[*pc++]
  DISPATCH();
  OPS(CASE)
L_STOP: return acc;
#undef DISPATCH
}

static long total;

static void run_void(const unsigned char *pc)
{
  static void *const tab[] = { OPS(TAB) &&L_END };
#define DISPATCH() goto *tab[*pc++]
#undef CASE
#define CASE(n) L##n: total += n; DISPATCH();
  DISPATCH();
  OPS(CASE)
L_END: ;
#undef DISPATCH
}

int main(void)
{
  static const unsigned char prog[] = { 0, 5, 23, 7, 7, 12, 24 };   /* 24 is L_STOP / L_END */
  long want = 0;
  int i, ok = 1;
  for (i = 0; i < 6; i++) { long n = prog[i]; want += 3 * (n + 1) * (n % 3 + 1); }
  if (run(prog) != want) { printf("run=%ld want %ld\n", run(prog), want); ok = 0; }
  run_void(prog);
  if (total != 0 + 5 + 23 + 7 + 7 + 12) { printf("total=%ld\n", total); ok = 0; }
  return ok ? 0 : 1;
}
