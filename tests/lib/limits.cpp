// EXPECT: 0
// <limits>: numeric_limits for the integer types.
#include <limits>
#include <cstdint>

static_assert(std::numeric_limits<int>::max() == 2147483647);
static_assert(std::numeric_limits<int>::min() == -2147483647 - 1);
static_assert(std::numeric_limits<unsigned>::max() == 4294967295u);
static_assert(std::numeric_limits<unsigned>::min() == 0u);
static_assert(std::numeric_limits<signed char>::min() == -128);
static_assert(std::numeric_limits<unsigned char>::max() == 255);
static_assert(std::numeric_limits<short>::max() == 32767);
static_assert(std::numeric_limits<unsigned short>::max() == 65535);
static_assert(std::numeric_limits<long long>::min() == -9223372036854775807LL - 1);
static_assert(std::numeric_limits<unsigned long long>::max() == 18446744073709551615ULL);
static_assert(std::numeric_limits<std::uint64_t>::max() == UINT64_MAX);
static_assert(std::numeric_limits<int>::digits == 31);
static_assert(std::numeric_limits<unsigned char>::digits == 8);
static_assert(std::numeric_limits<int>::is_signed && !std::numeric_limits<unsigned>::is_signed);
static_assert(std::numeric_limits<int>::is_integer && std::numeric_limits<int>::is_specialized);
static_assert(std::numeric_limits<bool>::max() && !std::numeric_limits<bool>::min());
static_assert(std::numeric_limits<unsigned>::lowest() == 0u);
static_assert(!std::numeric_limits<double>::is_specialized);  // floating point not provided yet

int main() {
  int fails = 0;
  int big = std::numeric_limits<int>::max();
  fails += big != 2147483647;
  fails += big == std::numeric_limits<int>::min();  // distinct values
  unsigned char uc = std::numeric_limits<unsigned char>::max();
  uc = static_cast<unsigned char>(uc + 1);   // wraps to 0, defined for unsigned
  fails += uc != 0;
  fails += std::numeric_limits<long>::max() != 9223372036854775807L;
  fails += std::numeric_limits<char>::digits < 7;
  return fails;
}
