// EXPECT: 0
// __builtin_bswap16/32/64 on runtime values (cproc has none: scripts/qbe-prep.rb supplies helpers).
#include <cstdint>
int main() {
  int bad = 0;
  volatile std::uint16_t a = 0x1234;
  volatile std::uint32_t b = 0x12345678u;
  volatile std::uint64_t c = 0x0102030405060708ull;
  if (__builtin_bswap16(a) != 0x3412) bad++;
  if (__builtin_bswap32(b) != 0x78563412u) bad++;
  if (__builtin_bswap64(c) != 0x0807060504030201ull) bad++;
  return bad;
}

