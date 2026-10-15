// EXPECT: 67
// HVX-style kernel: element-wise int16 add over local buffers (no globals, no tables), the
// shape a Hexagon HVX vadd loop would take. Exit code is a checksum of the output.
__attribute__((noinline)) void add_i16(short *dst, const short *a, const short *b, int n) {
  for (int i = 0; i < n; ++i) dst[i] = (short)(a[i] + b[i]);
}
int main() {
  short a[128], b[128], d[128];
  for (int i = 0; i < 128; ++i) { a[i] = (short)(i * 3 - 100); b[i] = (short)(1000 - i * 7); }
  add_i16(d, a, b, 128);
  int sum = 0;
  for (int i = 0; i < 128; ++i) sum += d[i];
  return (sum >> 8) & 255;
}
