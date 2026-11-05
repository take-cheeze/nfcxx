// EXPECT: 199
// A float conversion to a 1- or 2-byte integer truncates toward zero, and a value in the range is the same as the
// 4-byte conversion's. The g++ result is 199.
volatile double a = 127.9, b = -128.5;
volatile float c = 200.7f;
volatile double d = -32768.9, e = 65535.5;
int main() {
  signed char x = (signed char)a;
  signed char y = (signed char)b;
  unsigned char z = (unsigned char)c;
  short s = (short)d;
  unsigned short u = (unsigned short)e;
  return x + y + z + (s == -32768 ? 0 : 50) + (u == 65535 ? 0 : 60);
}
