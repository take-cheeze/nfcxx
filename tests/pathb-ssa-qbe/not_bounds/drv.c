#include <stdio.h>
#include <setjmp.h>
static jmp_buf buf;
void pathb_check(int cond, int code) { if (cond) longjmp(buf, code); }
int f(int n, int i);
static void run(int n, int i) {
  if (setjmp(buf)) printf("trap\n"); else printf("%d\n", f(n, i));
}
int main(void) {
  run(3, 2); run(0, 0); run(5, 1); run(2, -1); run(5, 9);
  return 0;
}
