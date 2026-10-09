/* HVX check (no EDG): one 128-byte vaddh over two int16 vectors. Expected exit 192 (= 68032 mod 256). */
typedef int HVX_Vector __attribute__((__vector_size__(128), __aligned__(128)));
static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}
void _start(void) {
  /* build two vectors of 64 halfwords with per-lane stores (no data sections) */
  volatile short a[64] __attribute__((aligned(128)));
  volatile short b[64] __attribute__((aligned(128)));
  volatile short d[64] __attribute__((aligned(128)));
  for (int i = 0; i < 64; ++i) { a[i] = (short)(i * 3); b[i] = (short)(1000 - i); }
  HVX_Vector va = *(const HVX_Vector *)a;
  HVX_Vector vb = *(const HVX_Vector *)b;
  HVX_Vector vd = __builtin_HEXAGON_V6_vaddh_128B(va, vb);
  *(HVX_Vector *)d = vd;
  int sum = 0;
  for (int i = 0; i < 64; ++i) sum += d[i];
  nfcxx_sys3(94, sum & 255, 0, 0);
  for (;;) {}
}
