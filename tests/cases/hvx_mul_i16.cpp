// EXPECT: 184
// HVX-style kernel: int16 multiply with a fixed-point shift, then a position-weighted checksum.
// Products of two int16 values fit in int, so the only wrap is the explicit (short) cast.
__attribute__((noinline)) void mul_q4_i16(short *dst, const short *a, const short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)((a[i] * b[i]) >> 4);
}
int main() {
  short a[96], b[96], d[96];
  for (int i = 0; i < 96; ++i) { a[i] = (short)(i * 37 - 1500); b[i] = (short)(3000 - i * 53); }
  mul_q4_i16(d, a, b, 96);
  unsigned acc = 0;
  for (int i = 0; i < 96; ++i) acc = acc * 31u + (unsigned short)d[i];
  return (int)(acc & 255u);
}
