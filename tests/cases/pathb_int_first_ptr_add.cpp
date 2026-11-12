// EXPECT: 0
// Path B -> QBE: a pointer addition whose integer operand comes first (`&got[(char *)p]`, `n + p`, sqlite's
// `pBuf = &((char *)pBuf)[got]`) is an (index BASE IDX SIZE) whose base is the pointer; with the operands swapped the int was
// the first operand of the pointer add (QBE: "invalid type for first operand in add").
#include <cstring>

__attribute__((noinline)) static char *advance(void *buf, int got) { return &((char *)buf)[got]; }
__attribute__((noinline)) static int *swapped(int *p, int n) { return n + p; }
__attribute__((noinline)) static short *subscripted(short *p, int n) { return &n[p]; }

int main() {
  char buf[16];
  int ints[8];
  short shorts[8];
  if (advance(buf, 5) != buf + 5) return 1;
  if (swapped(ints, 3) != ints + 3) return 2;
  if (subscripted(shorts, 6) != shorts + 6) return 3;
  if (advance(buf + 4, -2) != buf + 2) return 4;
  return 0;
}
