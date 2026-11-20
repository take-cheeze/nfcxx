/* Driver for the tests/pathb-hvx emitter probe: calls the emitted hvx_vec_mul_i16
   with the unsigned-first mixed-sign inputs and exits with the host-model
   checksum (184). Freestanding (no libc): raw syscalls like tests/hexagon/stub.c.
   The vector loads need 128-byte-aligned buffers. */
// EXPECT: 184
__attribute__((noinline)) void hvx_vec_mul_i16(short *dst, const unsigned short *a, const short *b, int n);
static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}
void _start(void) {
  static unsigned short a[96] __attribute__((aligned(128)));
  static short b[96] __attribute__((aligned(128)));
  static short d[96] __attribute__((aligned(128)));
  for (int i = 0; i < 96; ++i) { a[i] = (unsigned short)(3000 - i * 53); b[i] = (short)(i * 37 - 1500); }
  hvx_vec_mul_i16(d, a, b, 96);
  unsigned acc = 0;
  for (int i = 0; i < 96; ++i) acc = acc * 31u + (unsigned short)d[i];
  nfcxx_sys3(94, (int)(acc & 255u), 0, 0);
  for (;;) {}
}
