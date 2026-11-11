// EXPECT: 50
// Unsigned comparison and shifts, zero extension to a wider type, and an unsigned function argument.
unsigned int larger(unsigned int a, unsigned int b) { return a > b ? a : b; }
int main(void) {
  unsigned int big = 0xFFFFFFF0u;
  unsigned int small = 5u;
  int ult = small < big;                 /* 1: as signed, big is -16 and the compare would be 0 */
  unsigned int sh = big >> 28;           /* 15 */
  int sgn = (int)big >> 28;              /* -1 */
  unsigned long wide = big;              /* zero extended: 4294967280 */
  long hi = (long)(wide >> 31);          /* 1 */
  long low = (long)(big & 0xFFu);        /* 240 */
  unsigned short us = 0xFFFFu;
  int uext = (int)us;                    /* 65535 */
  return (int)larger(3, 9) + ult + (int)sh + sgn + (int)hi + (int)(low - 240) + (uext - 65535) + 25;   /* 9+1+15-1+1+0+0+25 */
}
