/* HVX check (no EDG): one 128-byte vrmpyubv over two uint8 vectors. Each of the 32
   output words is the dot product of a 4-byte group: d[i] = sum_j a[4*i+j]*b[4*i+j].
   Expected exit is computed against the scalar reference below. */
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
  /* build two vectors of 128 bytes with per-lane stores (no data sections) */
  volatile unsigned char a[128] __attribute__((aligned(128)));
  volatile unsigned char b[128] __attribute__((aligned(128)));
  volatile unsigned d[32] __attribute__((aligned(128)));
  for (int i = 0; i < 128; ++i) { a[i] = (unsigned char)(i * 3 + 1); b[i] = (unsigned char)(i * 5 + 7); }
  HVX_Vector va = *(const HVX_Vector *)a;
  HVX_Vector vb = *(const HVX_Vector *)b;
  HVX_Vector vd = __builtin_HEXAGON_V6_vrmpyubv_128B(va, vb);
  *(HVX_Vector *)d = vd;
  int sum = 0, ref = 0;
  for (int i = 0; i < 32; ++i) sum += (int)d[i];
  for (int i = 0; i < 32; ++i) {
    int dot = 0;
    for (int j = 0; j < 4; ++j) dot += (int)a[4 * i + j] * (int)b[4 * i + j];
    ref += dot;
  }
  nfcxx_sys3(94, ((sum == ref) ? sum : 0xDEAD) & 255, 0, 0);
  for (;;) {}
}
