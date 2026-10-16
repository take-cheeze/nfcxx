// EXPECT: 0
// GNU-VERSION: 140000 (GCC 14 emulation: EDG knows the g-builtins only from GCC 14 on)
// GCC 14 type-generic bit builtins: __builtin_clzg / ctzg (two-argument form: d for a zero input), popcountg,
// parityg. Values come from gcc 14 (the same probe built with gcc). The inputs are volatile so EDG does not fold them.
static volatile unsigned int vu = 0;
static volatile unsigned long vl = 0;
int main() {
  int fails = 0;
  unsigned int z = vu;                  // 0
  unsigned int one = vu + 1u;           // 1
  unsigned int hi = vu + 0x00010000u;   // bit 16
  fails += __builtin_clzg(z, 64) != 64;
  fails += __builtin_clzg(one, 64) != 31;
  fails += __builtin_clzg(hi, 64) != 15;
  fails += __builtin_clzg(z, 7) != 7;
  fails += __builtin_clzg(hi, 7) != 15;
  fails += __builtin_ctzg(z, 40) != 40;
  fails += __builtin_ctzg(one, 40) != 0;
  fails += __builtin_ctzg(hi, 40) != 16;
  fails += __builtin_clzg(one) != 31;
  fails += __builtin_ctzg(hi) != 16;
  fails += __builtin_popcountg(vu + 0xf0f0u) != 8;
  fails += __builtin_popcountg(z) != 0;
  fails += __builtin_parityg(vu + 7u) != 1;
  fails += __builtin_parityg(vu + 3u) != 0;

  unsigned long lz = vl;                // 0
  unsigned long lone = vl + 1ul;        // 1
  unsigned long lhi = vl + (1ul << 40); // bit 40
  fails += __builtin_clzg(lz, 64) != 64;
  fails += __builtin_clzg(lone, 64) != 63;
  fails += __builtin_clzg(lhi, 64) != 23;
  fails += __builtin_clzg(lz, 5) != 5;
  fails += __builtin_ctzg(lz, 64) != 64;
  fails += __builtin_ctzg(lone, 64) != 0;
  fails += __builtin_ctzg(lhi, 64) != 40;
  fails += __builtin_ctzg(lz, 9) != 9;
  fails += __builtin_popcountg(lhi) != 1;
  fails += __builtin_popcountg(lz) != 0;
  return fails;
}
