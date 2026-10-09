// EXPECT: 14
// Integer probes for the emitter: division and remainder signs, shifts, narrow wrap, unsigned compares and
// conversions, 64-bit values, bool. Values come through noinline functions so no constant folding happens.
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) unsigned uid(unsigned x) { return x; }
int main() {
  int r = 0;
  r += id(-7) / 2 == -3;                  // truncates toward zero
  r += id(-7) % 2 == -1;                  // remainder takes the sign of the dividend
  r += id(7) / -2 == -3;
  r += (id(-8) >> 1) == -4;               // arithmetic shift for signed
  r += (uid(0x80000000u) >> 31) == 1;     // logical shift for unsigned
  r += (id(3) << 4) == 48;
  unsigned char uc = (unsigned char)id(300);
  signed char sc = (signed char)id(200);
  r += uc == 44;
  r += sc == -56;
  short sh = (short)id(70000);
  r += sh == 4464;
  unsigned u = uid(3000000000u);
  r += u > 2000000000u;
  r += (id(-1) < 0u) == 0;                // -1 converts to a large unsigned value
  long long big = (long long)id(-5) * 1000000000LL;
  r += big == -5000000000LL;
  r += (unsigned long long)big > 0;
  bool b = id(2) > 1;
  r += b;
  return r;
}
