// EXPECT: 247
// Integer arithmetic, wrapping of narrow types, division, shifts, comparisons.
int main() {
  int a = 1000003;
  int b = -7;
  unsigned int u = 4000000000u;
  unsigned char c = 250;
  signed char sc = 120;
  short s = 30000;
  long long big = 1LL << 40;
  int r = 0;
  r += a / 7;          // division toward zero
  r += b % 3;          // remainder takes the dividend's sign
  r += (int)(u >> 28); // unsigned shift
  c += 10;             // wraps at 8 bits
  r += c;
  sc += 10;            // signed wrap
  r += sc;
  s += s;              // wraps at 16 bits
  r += s < 0 ? 1 : 0;
  r += (int)(big >> 38);
  r += (b >> 1) & 3;   // arithmetic right shift of a negative value
  r += ((unsigned)b >> 28) & 1;
  r ^= 0x55;
  r |= 0x100;
  r &= 0x1ff;
  return r & 0xff;
}
