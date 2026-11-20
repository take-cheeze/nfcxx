/* HVX widening-multiply lane semantics (no EDG; see docs/notes/hexagon.md section 5).
   Verified on qemu-hexagon (8.2.2, noble qemu-user-static):
   - V6_vmpyhv_128B (vec x vec) and V6_vmpyhus_128B (signed x unsigned): full
     64-lane widening, lane-aligned, deinterleaved as V0 = even-lane products,
     V1 = odd-lane products.
   - V6_vmpyh_128B (vec x scalar Rt): V0 holds the even-lane products; V1 reads
     zero on this qemu. Real hardware may put the odd-lane products in V1, so
     V1 is NOT asserted for the scalar form here.
   Exit: low 8 bits of the folded checksum of every asserted product, or
   200+fails when an assertion misses. */
typedef int V128 __attribute__((__vector_size__(128), __aligned__(128)));
typedef long VP256 __attribute__((__vector_size__(256), __aligned__(256)));

static long nfcxx_sys3(long n, long a, long b, long c) {
  register long r6 __asm__("r6") = n;
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  __asm__ volatile("trap0(#0)" : "+r"(r0) : "r"(r6), "r"(r1), "r"(r2) : "memory");
  return r0;
}

#define LANES 64
#define HALF 32
void _start(void) {
  volatile short vs[LANES] __attribute__((aligned(128)));
  volatile short vu[LANES] __attribute__((aligned(128)));
  volatile unsigned short uu[LANES] __attribute__((aligned(128)));
  volatile int got[LANES] __attribute__((aligned(128)));
  for (int i = 0; i < LANES; ++i) {
    vs[i] = (short)(i - 32);
    vu[i] = (short)(100 + i);
    uu[i] = (unsigned short)(100 + i);
  }
  int fails = 0;
  unsigned acc = 0;

  /* vec x vec, signed: V0 = even lanes, V1 = odd lanes. */
  {
    V128 a = *(const V128 *)vs, b = *(const V128 *)vu;
    VP256 w = __builtin_HEXAGON_V6_vmpyhv_128B(a, b);
    *(VP256 *)got = w;
    for (int i = 0; i < HALF; ++i) {
      int e = (int)vs[2 * i] * (int)vu[2 * i];
      int o = (int)vs[2 * i + 1] * (int)vu[2 * i + 1];
      if (((int *)got)[i] != e || ((int *)got)[HALF + i] != o) fails++;
      acc = acc * 31u + (unsigned)(((int *)got)[i] ^ ((int *)got)[HALF + i]);
    }
  }

  /* vec x vec, signed x unsigned: same layout, unsigned second operand. */
  {
    V128 a = *(const V128 *)vs, b = *(const V128 *)uu;
    VP256 w = __builtin_HEXAGON_V6_vmpyhus_128B(a, b);
    *(VP256 *)got = w;
    for (int i = 0; i < HALF; ++i) {
      int e = (int)vs[2 * i] * (int)uu[2 * i];
      int o = (int)vs[2 * i + 1] * (int)uu[2 * i + 1];
      if (((int *)got)[i] != e || ((int *)got)[HALF + i] != o) fails++;
      acc = acc * 31u + (unsigned)(((int *)got)[i] ^ ((int *)got)[HALF + i]);
    }
  }

  /* vec x scalar: only the V0 even-lane half is asserted (see header). */
  {
    V128 a = *(const V128 *)vu;
    int rt = 0x00000007;
    VP256 w = __builtin_HEXAGON_V6_vmpyh_128B(a, rt);
    *(VP256 *)got = w;
    for (int i = 0; i < HALF; ++i) {
      int e = (int)vu[2 * i] * 7;
      if (((int *)got)[i] != e) fails++;
      acc = acc * 31u + (unsigned)((int *)got)[i];
    }
  }

  nfcxx_sys3(94, (fails ? 200 + (fails & 63) : acc & 255), 0, 0);
  for (;;) {}
}
