/* Driver for the tests/pathb-hvx emitter probe: calls the emitted hvx_vec_add_i16
   with the tests/cases/hvx_add_i16.cpp inputs and exits with its checksum (67).
   Freestanding (no libc): raw syscalls like tests/hexagon/stub.c. The vector
   loads need 128-byte-aligned buffers. */
// EXPECT: 67
__attribute__((noinline)) void hvx_vec_add_i16(short *dst, const short *a, const short *b, int n);
static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}
void _start(void) {
  static short a[128] __attribute__((aligned(128)));
  static short b[128] __attribute__((aligned(128)));
  static short d[128] __attribute__((aligned(128)));
  for (int i = 0; i < 128; ++i) { a[i] = (short)(i * 3 - 100); b[i] = (short)(1000 - i * 7); }
  hvx_vec_add_i16(d, a, b, 128);
  int sum = 0;
  for (int i = 0; i < 128; ++i) sum += d[i];
  nfcxx_sys3(94, (sum >> 8) & 255, 0, 0);
  for (;;) {}
}
