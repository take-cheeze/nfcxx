// EXPECT: 0
// <cstddef> and <cstdint>: type sizes, std::byte operators, nullptr_t, offsetof.
#include <cstddef>
#include <cstdint>

static_assert(sizeof(std::size_t) == sizeof(void*));
static_assert(sizeof(std::ptrdiff_t) == sizeof(void*));
static_assert(sizeof(std::nullptr_t) == sizeof(void*));
static_assert(sizeof(std::byte) == 1);
static_assert(sizeof(std::int32_t) == 4 && sizeof(std::uint64_t) == 8);

struct Rec { char c; int i; double d; };
static_assert(offsetof(Rec, i) == 4);

int main() {
  int fails = 0;
  std::byte b = std::byte{0x12};
  fails += std::to_integer<int>(b << 4) != 0x20;
  fails += std::to_integer<int>(b >> 4) != 0x1;
  fails += std::to_integer<int>(b | std::byte{0x01}) != 0x13;
  fails += std::to_integer<int>(b & std::byte{0x10}) != 0x10;
  fails += std::to_integer<int>(b ^ std::byte{0xff}) != 0xed;
  fails += std::to_integer<int>(~b) != 0xed;
  b |= std::byte{0x40};
  fails += std::to_integer<unsigned>(b) != 0x52;

  std::nullptr_t np = nullptr;
  fails += np != nullptr;

  std::int8_t  i8  = 127;   fails += i8 != 127;
  std::int16_t i16 = -32768; fails += i16 != -32768;
  std::int32_t i32 = INT32_MIN; fails += i32 != INT32_MIN;
  std::int64_t i64 = INT64_MAX; fails += i64 != INT64_MAX;
  std::uint8_t u8 = 255;    fails += u8 != UINT8_MAX;
  std::uint16_t u16 = 65535; fails += u16 != UINT16_MAX;
  std::uint32_t u32 = 0xffffffffu; fails += u32 != UINT32_MAX;
  std::uint64_t u64 = UINT64_MAX; fails += u64 != 18446744073709551615ull;

  // wrap-around is defined for unsigned types
  std::uint8_t w = 250; w += 10; fails += w != 4;
  // offsetof on a runtime-checked layout
  fails += offsetof(Rec, d) != 8;
  return fails;
}
