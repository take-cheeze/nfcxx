/* HVX vector-plus-scalar-tail loop shape (no EDG; see docs/notes/hexagon.md section 5).
   The shape Path B must emit for loops whose trip count is not a multiple of the
   128-byte vector width (64 int16 lanes): a vaddh vector main loop plus a scalar tail.
   Covers a mid-size n (100: one vector + 36 tail), a sub-vector n (5: tail only),
   and n = 0. Exit is the folded checksum (expect 183), or 200+fails on mismatch. */
typedef int V128 __attribute__((__vector_size__(128), __aligned__(128)));

static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}

static void add_tail(short *dst, const short *a, const short *b, int n) {
  int i = 0;
  for (; i + 64 <= n; i += 64) {
    V128 va = *(const V128 *)(a + i);
    V128 vb = *(const V128 *)(b + i);
    *(V128 *)(dst + i) = __builtin_HEXAGON_V6_vaddh_128B(va, vb);
  }
  for (; i < n; ++i) dst[i] = (short)(a[i] + b[i]);
}

#define NMAX 128
void _start(void) {
  volatile short a[NMAX] __attribute__((aligned(128)));
  volatile short b[NMAX] __attribute__((aligned(128)));
  volatile short d[NMAX] __attribute__((aligned(128)));
  for (int i = 0; i < NMAX; ++i) {
    a[i] = (short)(i * 3 - 100);
    b[i] = (short)(1000 - i * 7);
  }
  int fails = 0;
  unsigned acc = 0;
  const int ns[3] = {100, 5, 0};
  for (int k = 0; k < 3; ++k) {
    int n = ns[k];
    for (int i = 0; i < n; ++i) d[i] = 0;
    add_tail((short *)d, (const short *)a, (const short *)b, n);
    for (int i = 0; i < n; ++i) {
      short want = (short)(a[i] + b[i]);
      if (d[i] != want) fails++;
      acc = acc * 31u + (unsigned short)d[i];
    }
  }
  nfcxx_sys3(94, (fails ? 200 + (fails & 63) : acc & 255), 0, 0);
  for (;;) {}
}
