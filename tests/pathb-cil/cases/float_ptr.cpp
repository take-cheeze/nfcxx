// EXPECT: 12
// Path B CIL spike: fneg (negation of a double), a volatile load (load.v), a pointer difference (pdiff) and a compiler
// barrier (asm with a memory clobber). (e == 2.5 ? 2 : 0) + 7 + 3.
static int arr[8];
volatile int v = 7;
static double neg(double d) { return -d; }
int main(void) {
  double e = neg(-2.5);
  int *p = arr + 3;
  long diff = p - arr;
  int r = (e == 2.5 ? 2 : 0) + v + (int)diff;
  asm("" ::: "memory");
  return r;
}
