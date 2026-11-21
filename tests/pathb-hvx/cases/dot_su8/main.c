/* Driver for the tests/pathb-hvx emitter probe: calls the emitted hvx_vec_dot_su8
   and exits with the host-model checksum. Freestanding (no libc): raw syscalls
   like tests/hexagon/stub.c. The vector loads need 128-byte-aligned buffers.
   n = 300 covers two full vectors plus a 44-byte tail. */
// EXPECT: 80
__attribute__((noinline)) int hvx_vec_dot_su8(const unsigned char *a, const signed char *b, int n);
static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}
void _start(void) {
  static unsigned char a[300] __attribute__((aligned(128)));
  static signed char b[300] __attribute__((aligned(128)));
  for (int i = 0; i < 300; ++i) { a[i] = (unsigned char)(i * 3 + 1); b[i] = (signed char)((i * 7) % 256 - 128); }
  int got = hvx_vec_dot_su8(a, b, 300);
  nfcxx_sys3(94, got & 255, 0, 0);
  for (;;) {}
}
