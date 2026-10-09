/* A volatile local written between setjmp and longjmp must keep the written value (C11 7.13.2.1).
   QBE promotes a local whose address is never taken to a register, so qbe-prep.py keeps volatile locals
   in memory. Prints the values read after the longjmp. */
/* EXPECT: 42 */
#include <setjmp.h>
#include <stdio.h>

static jmp_buf jb;

static void jump(void) { longjmp(jb, 1); }

int main(void) {
  volatile int v = 1;
  volatile long a = 10, *p = 0, b = 20;
  int * volatile q = 0;
  static int dummy;
  if (setjmp(jb) == 0) {
    v = 42;
    a = 7;
    b = 8;
    q = &dummy;
    jump();
  }
  printf("v=%d a=%ld b=%ld q=%d p=%d\n", v, a, b, q == &dummy, p == 0);
  return (a == 7 && b == 8 && q == &dummy && p == 0) ? v : 1;
}
