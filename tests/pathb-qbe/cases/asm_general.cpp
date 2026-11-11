// General inline assembly (be/nfcxx_ir.c's asm-block, scripts/pathb-ssa-qbe.rb's helper): a tied register operand, a memory
// operand, a 64-bit register, fixed registers (a, b, c, d) with a cpuid-like instruction, byte and word operands with the
// %b and %w modifiers, and float and double operands in SSE registers. The exit code is the number of wrong results.
// EXPECT: 0
#include <cstdio>

static int add_asm(int a, int b) {
  int r;
  __asm__("addl %2, %0" : "=r"(r) : "0"(a), "r"(b));
  return r;
}

static void inc_mem(int *p) { __asm__("addl $1, %0" : "+m"(*p)); }

static unsigned long long shl3(unsigned long long v) {
  unsigned long long r;
  __asm__("movq %1, %0\n\tshlq $3, %0" : "=r"(r) : "r"(v));
  return r;
}

static unsigned rdtsc_free_leaf0(unsigned leaf, unsigned *a, unsigned *b, unsigned *c, unsigned *d) {
  // cpuid: a, b, c, d are fixed registers; the vendor string's length (leaf 0) is in eax, the values vary by CPU, so
  // only the leaf-0 eax (the highest basic leaf, at least 1 on every x86-64 CPU) is checked.
  __asm__("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf), "c"(0u));
  return *a;
}

static unsigned char rol4(unsigned char v) {
  unsigned char r = v;
  __asm__("rolb $4, %b0" : "+q"(r));
  return r;
}

static unsigned short add16(unsigned short a, unsigned short b) {
  unsigned short r = a;
  __asm__("addw %1, %w0" : "+r"(r) : "r"(b));
  return r;
}

static float fadd(float a, float b) {
  float r = a;
  __asm__("addss %1, %0" : "+x"(r) : "x"(b));
  return r;
}

static double dmul(double a, double b) {
  double r;
  __asm__("movsd %1, %0\n\tmulsd %2, %0" : "=x"(r) : "x"(a), "x"(b));
  return r;
}

int main() {
  int bad = 0;
  if (add_asm(3, 4) != 7) ++bad;
  int x = 5;
  inc_mem(&x);
  if (x != 6) ++bad;
  if (shl3(2) != 16) ++bad;
  unsigned a = 0, b = 0, c = 0, d = 0;
  if (rdtsc_free_leaf0(0, &a, &b, &c, &d) == 0) ++bad;
  if (rol4(0x12) != 0x21) ++bad;
  if (add16(40000, 30000) != 4464) ++bad;
  if (fadd(1.5f, 2.25f) != 3.75f) ++bad;
  if (dmul(1.5, 4.0) != 6.0) ++bad;
  std::printf("asm bad %d\n", bad);
  return bad;
}
