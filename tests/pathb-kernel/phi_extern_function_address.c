// The address of a function that this file declares and the C library defines, as an operand of a phi (the kernel's
// `__irq_do_set_handler`: `if (!handle) handle = handle_bad_irq;` and then `handle == handle_bad_irq`). The emitter loads
// such an address from a pointer cell, and put the load ahead of the phi in its block, where QBE refuses it
// ("unexpected phi instruction"); the operand must also be defined on its edge, so the predecessor computes it.
#include <stdlib.h>
typedef int (*handler)(int);
static int mine(int n) { return n + 1; }

__attribute__((noinline)) static int pick(handler h, handler *out)
{
  if (!h)
    h = abs;
  *out = h;
  return h == abs;
}

__attribute__((noinline)) static int pick_n(handler h, int n, handler *out)
{
  int i;
  for (i = 0; i < n; i++) {
    if (!h)
      h = abs;
    else
      h = mine;
  }
  *out = h;
  return h == abs;
}

int main(void)
{
  handler h;
  int a = pick(0, &h);
  int r = h(-5);
  int b = pick(mine, &h);
  int c = pick_n(0, 1, &h);
  int d = pick_n(mine, 2, &h);
  return a == 1 && r == 5 && b == 0 && c == 1 && d == 0 ? 7 : 1;
}
