// EXPECT: 0
// __builtin_clz / ctz / popcount (and the l / ll variants).
int main() {
  int fails = 0;
  fails += __builtin_clz(1u) != 31;
  fails += __builtin_clz(0x80000000u) != 0;
  fails += __builtin_clz(0x00010000u) != 15;
  fails += __builtin_ctz(8u) != 3;
  fails += __builtin_ctz(1u) != 0;
  fails += __builtin_popcount(0xf0f0u) != 8;
  fails += __builtin_popcount(0u) != 0;
  fails += __builtin_clzll(1ull) != 63;
  fails += __builtin_ctzll(1ull << 40) != 40;
  fails += __builtin_popcountll(0xffffffffffffffffull) != 64;
  fails += __builtin_clzl(1ul) != (sizeof(long) * 8 - 1);
  return fails;
}
