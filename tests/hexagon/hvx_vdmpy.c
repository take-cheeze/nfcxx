/* HVX check (no EDG): vdmpybus mixed-sign widening dot. Vd32.h = vdmpy(Vu32.ub, Rt32.b):
   each output pair comes from one 4-byte group: out[2i] = in[4i]*Rt[0] + in[4i+1]*Rt[1],
   out[2i+1] = in[4i+2]*Rt[2] + in[4i+3]*Rt[3]. Exit is a checksum of all 64 lanes
   against the scalar model. */
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
  volatile unsigned char a[128] __attribute__((aligned(128)));
  volatile short d[64] __attribute__((aligned(128)));
  for (int i = 0; i < 128; ++i) a[i] = (unsigned char)(i * 3 + 1);
  HVX_Vector va = *(const HVX_Vector *)a;
  int rt = 0x04030201;
  HVX_Vector vd = __builtin_HEXAGON_V6_vdmpybus_128B(va, rt);
  *(HVX_Vector *)d = vd;
  int sum = 0, ref = 0;
  for (int i = 0; i < 64; ++i) sum += d[i];
  for (int i = 0; i < 32; ++i) {
    int lo = (int)a[4 * i] * 1 + (int)a[4 * i + 1] * 2;
    int hi = (int)a[4 * i + 2] * 3 + (int)a[4 * i + 3] * 4;
    ref += lo + hi;
  }
  nfcxx_sys3(94, ((sum == ref) ? sum : 0xDEAD) & 255, 0, 0);
  for (;;) {}
}
