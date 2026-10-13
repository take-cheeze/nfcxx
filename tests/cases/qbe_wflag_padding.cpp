// EXPECT: 0
// X86-ONLY: the EDG front end on aarch64 rejects a long double literal (x86-64 long double layout), so this case is skipped there
// A struct with a 4-byte member next to tail padding (an integer-or-float number: 8-byte union + int flag, 16 bytes), copied by value
// and then tested through the 4-byte member. QBE's load elimination makes the 4-byte load a "w copy" of the 8-byte copy of the same
// slot, copy elimination hands the jnz that long temporary, and amd64 isel fused the long "and" (which keeps the padding half)
// into a 64-bit testq: the branch looked at the padding bytes, so an integer came back as if it were a float and a float as its
// integer part (found with nfcast's nfcr_N; scripts/qbe-wflag.patch, docs/notes/qbe-wflag.md). The stack is filled with 0xff first
// so that the padding of the uninitialized slots is nonzero.
#include <string.h>

union W { long long i; double d; };
struct N { W w; int f; };  // f: 1 the value is w.d, 0 it is w.i

static long long depth, maxd = 100;
static unsigned char sink;
static void bail() { depth = 0; }

static inline N num_i(long long i) { N n; n.w.i = i; n.f = 0; return n; }
static inline N num_f(double d) { N n; n.w.i = 0; n.w.d = d; n.f = 1; return n; }
static inline double num_d(N n) { return n.f ? n.w.d : (double)n.w.i; }

// local r = a; if b > 2 then r = r * 1.5 end; return r
__attribute__((noinline)) static N mix(long long a, long long b) {
  N v = num_i(0);
  if (depth >= maxd) bail();
  ++depth;
  v = num_i(a);
  if (b > 2) v = num_f(num_d(v) * 1.5);
  N t = v;
  --depth;
  return t;
}

__attribute__((noinline)) static void dirty() {
  unsigned char junk[512];
  memset(junk, 0xff, sizeof junk);
  sink = junk[7];
}

int main() {
  int bad = 0;
  dirty();
  N x = mix(3, 1);
  if (x.f != 0 || x.w.i != 3) bad |= 1;
  dirty();
  N y = mix(3, 5);
  if (y.f != 1 || y.w.d != 4.5) bad |= 2;
  dirty();
  N z = mix(4, 9);
  if (z.f != 1 || z.w.d != 6.0) bad |= 4;
  return bad;
}
