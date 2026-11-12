/* EXPECT: 0 */
/* GNU C computed goto: label addresses (&&label), `goto *ptr`, a static dispatch table of label addresses (Lua's lvm.c
   and the ljumptab.h pattern), a label address kept in a local, a table indexed at run time, and a pointer compare.
   Self-checking: every value is what gcc produces. */
#include <stdio.h>

enum { OP_INC, OP_DBL, OP_NEG, OP_STOP };

static int run(const unsigned char *code)
{
  static const void *const tab[] = { &&L_INC, &&L_DBL, &&L_NEG, &&L_STOP };
  const unsigned char *pc = code;
  int acc = 1;
#define DISPATCH() goto *tab[*pc++]
  DISPATCH();
L_INC: acc += 3; DISPATCH();
L_DBL: acc *= 2; DISPATCH();
L_NEG: acc = -acc; DISPATCH();
L_STOP: return acc;
#undef DISPATCH
}

static int local_ptr(int n)
{
  void *p = n ? &&yes : &&no;
  int r = 0;
  if (p == &&yes) r += 10;
  goto *p;
yes: r += 1; return r;
no: r += 2; return r;
}

static int loop_count(int n)
{
  void *back = &&top;
  int i = 0;
top:
  if (i < n) { i++; goto *back; }
  return i;
}

int main(void)
{
  static const unsigned char prog[] = { OP_INC, OP_DBL, OP_NEG, OP_INC, OP_STOP }; /* ((1+3)*2 negated)+3 */
  int ok = 1;
  if (run(prog) != -5) { printf("run=%d\n", run(prog)); ok = 0; }
  if (local_ptr(1) != 11) { printf("local_ptr(1)=%d\n", local_ptr(1)); ok = 0; }
  if (local_ptr(0) != 2) { printf("local_ptr(0)=%d\n", local_ptr(0)); ok = 0; }
  if (loop_count(7) != 7) { printf("loop_count=%d\n", loop_count(7)); ok = 0; }
  return ok ? 0 : 1;
}
