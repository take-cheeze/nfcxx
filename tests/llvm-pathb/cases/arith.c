// EXPECT: 67
// Integer arithmetic, bit operations, shifts and conversions. nsw add, sub and mul are checked in the IR.
int main(void) {
  int a = 7, b = -3;
  int r = a * b + 10;                    /* -11 */
  r = r / 2 + r % 4;                     /* -5 + -3 = -8 */
  unsigned int u = 0xF0F0u;
  unsigned int s = (u >> 4) ^ (u << 2); /* 0x0F0F ^ 0x3C3C0 */
  long x = (long)a << 33;
  short sh = (short)-5;
  char c = (char)200;                    /* -56 as signed char */
  int ext = (int)c + (int)sh;            /* -56 + -5 = -61 */
  unsigned char uc = (unsigned char)c;   /* 200 */
  return (r + 8) + (int)(s & 0x7f) * 0 + (int)(x >> 33) + (ext + 61) + (uc - 200) + 60;   /* 0 + 7 + 0 + 60 */
}
