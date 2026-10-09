/* EXPECT: 17 */
/* Arithmetic and control flow. */
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) {
  int s = 0;
  for (int i = 1; i <= 10; i++) { if (i % 3 == 0) continue; s += i * i; }  /* 1+4+16+25+49+64+100 = 259 */
  int k = 0;
  while (k < 5) k++;
  do { k += 2; } while (k < 9);                                           /* 5,7,9 */
  switch (k) { case 9: s += 1; break; default: s = 0; }                   /* 260 */
  unsigned u = 0xffffffffu; u += 2;                                       /* 1 */
  long l = 1L << 40;
  s += (int)(l >> 38) + (int)u + fib(10);                                 /* 4 + 1 + 55 */
  return s % 101 + (s == 320 ? 0 : 1);                                    /* 320 % 101 = 17 */
}
