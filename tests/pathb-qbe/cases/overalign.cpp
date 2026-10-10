// EXPECT: 0
// Over-aligned objects: globals (QBE `data ... align N`), a function-local static, locals (QBE stack slots are
// 16-aligned, so the emitter over-allocates and rounds the address) and a struct member. Checks the address modulo
// and the values; the gcc backend must agree.
#include <cstdint>

alignas(32) int g32 = 7;
alignas(64) char g64[10] = {1, 2, 3};
struct alignas(32) S32 { int v; };
S32 gs = {11};
struct M { char c; alignas(64) int v; };
M gm = {1, 13};

static int mod(const void *p, unsigned n) { return (int)(reinterpret_cast<std::uintptr_t>(p) % n); }

__attribute__((noinline)) static int use(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) { p[i] = i + 1; s += p[i]; }
  return s;
}

int main() {
  int bad = 0;
  if (mod(&g32, 32) || g32 != 7) bad |= 1;
  if (mod(g64, 64) || g64[2] != 3) bad |= 2;
  if (mod(&gs, 32) || gs.v != 11 || sizeof(S32) != 32) bad |= 8;
  if (mod(&gm.v, 64) || gm.v != 13 || sizeof(M) != 128) bad |= 16;
  alignas(32) int l32[4];
  alignas(64) int l64[8];
  int plain[3];
  if (mod(l32, 32) || use(l32, 4) != 10 || l32[3] != 4) bad |= 32;
  if (mod(l64, 64) || use(l64, 8) != 36 || l64[7] != 8) bad |= 64;
  if (use(plain, 3) != 6) bad |= 128;
  S32 ls = {5};
  if (mod(&ls, 32) || ls.v != 5) bad |= 256;
  alignas(64) static int sl = 3;
  if (mod(&sl, 64) || sl != 3) bad |= 512;
  return bad;
}
