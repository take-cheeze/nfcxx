// GCC 14's type-generic bit built-ins, which <bit> calls (countl_zero and friends, through libstdc++'s headers): clzg and
// ctzg take an optional fallback for 0, popcountg and parityg count bits; each width is the argument's type, including
// unsigned __int128 (the helpers of be/nfcxx_ldrt.c count over both halves). Without the lowering they became calls of
// an undefined `clzg`. Expected output: none; the exit status is the number of wrong results.
// EXPECT: 0
// NFCXX-FLAGS: --gnu-version=140000
int check_bits() {
  int bad = 0;
  unsigned u32 = 0x00f0u; unsigned long long u64 = 0x10ull; unsigned short u16 = 0x0100; unsigned char u8 = 0x01;
  if (__builtin_clzg(u32) != 24) bad |= 1;
  if (__builtin_clzg(u64) != 59) bad |= 2;
  if (__builtin_clzg(u16) != 7) bad |= 4;
  if (__builtin_clzg(u8) != 7) bad |= 8;
  if (__builtin_clzg(0u, 32) != 32) bad |= 16;
  if (__builtin_clzg(u32, 32) != 24) bad |= 32;
  if (__builtin_ctzg(u32) != 4) bad |= 64;
  if (__builtin_ctzg(0ull, 64) != 64) bad |= 128;
  if (__builtin_popcountg(u32) != 4) bad |= 256;
  if (__builtin_parityg(u32) != 0) bad |= 512;
  if (__builtin_parityg(u64) != 1) bad |= 1024;
  unsigned __int128 one = 1, hi = (unsigned __int128)1 << 100, lo = 0x30;
  if (__builtin_clzg(one) != 127) bad |= 2048;
  if (__builtin_clzg(hi) != 27) bad |= 4096;
  if (__builtin_ctzg(lo) != 4) bad |= 8192;
  if (__builtin_ctzg(hi) != 100) bad |= 16384;
  if (__builtin_popcountg(hi | lo) != 3) bad |= 32768;
  if (__builtin_clzg((unsigned __int128)0, 128) != 128) bad |= 65536;
  return bad;
}
int main() { return check_bits(); }
