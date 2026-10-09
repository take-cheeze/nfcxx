/* EXPECT: 39 */
/* Function pointers: tables, callbacks, qsort from libc, pointers to pointers. */
#include <stdlib.h>
static int add(int a, int b) { return a + b; }
static int mul(int a, int b) { return a * b; }
static int apply(int (*f)(int, int), int a, int b) { return f(a, b); }
static int cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
typedef int (*binop)(int, int);
int main(void) {
  binop tab[2] = { add, mul };
  int r = apply(tab[0], 3, 4) + apply(tab[1], 3, 4);   /* 7 + 12 = 19 */
  int v[5] = { 5, 3, 9, 1, 7 };
  qsort(v, 5, sizeof v[0], cmp);
  binop *pp = &tab[1];
  return r + v[0] * 10 + v[4] + (*pp)(1, 1) + (v[2] == 5 ? 0 : 100);   /* 19 + 10 + 9 + 1 */
}
