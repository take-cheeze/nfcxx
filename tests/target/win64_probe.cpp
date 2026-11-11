// TARGET: win64 x86_64-w64-mingw32
// HOST-REJECTS: yes
// NEEDS: mingw   (the win64 table is MinGW's only when MinGW was installed at setup, scripts/setup-edg.sh)
// RUN-WINE: 42
// Windows (LLP64, MinGW-w64 headers and gcc): EDG's win64 layout facts, the lib/ integer types, and a run under wine.
// Built with the MinGW gcc, not with clang, because the program links against MinGW's CRT.
#include <cstddef>
#include <cstdint>
static_assert(sizeof(void*) == 8, "pointers are 64-bit");
static_assert(sizeof(long) == 4, "long is 32-bit (LLP64)");
static_assert(char(255) < 0, "char is signed on x86");
static_assert(sizeof(std::uint64_t) == 8, "uint64_t from lib/cstdint");
static_assert(sizeof(std::int16_t) == 2, "int16_t from lib/cstdint");
int main() {
  std::uint64_t acc = 0;
  for (std::uint32_t i = 1; i <= 8; ++i) acc += std::uint64_t(i) * i;   // 1+4+...+64 = 204
  std::int16_t s = -3;
  return int(acc - 162) + (s < 0 ? 0 : 1);   // 204 - 162 = 42
}
