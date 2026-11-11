// EXPECT: 5
// STDOUT: same
// `reinterpret_cast<T&>(x)` of an object of another type of the same size (type punning through a reference cast, the
// MSVC STL tests' as_bits/from_bits). EDG lowers it to an lvalue_adjust to the new type; the back end read the object
// with the type of the operand (a float) and gave that value to a context of the new type (an unsigned): a `float`
// returned from a function that returns `unsigned`, which QBE refused ("invalid type for jump argument").
#include <cstdint>
#include <cstdio>

static std::uint32_t as_bits(float const value) { return reinterpret_cast<std::uint32_t const&>(value); }
static std::uint64_t as_bits(double const value) { return reinterpret_cast<std::uint64_t const&>(value); }
static float from_bits(std::uint32_t const bits) { return reinterpret_cast<float const&>(bits); }
static double from_bits(std::uint64_t const bits) { return reinterpret_cast<double const&>(bits); }

int main() {
  int bad = 0;
  if (as_bits(1.0f) != 0x3f800000u) bad |= 1;
  if (as_bits(2.0) != 0x4000000000000000ull) bad |= 2;
  if (from_bits(std::uint32_t(0x40490fdbu)) < 3.14159f || from_bits(std::uint32_t(0x40490fdbu)) > 3.1416f) bad |= 4;
  if (from_bits(std::uint64_t(0x3ff0000000000000ull)) != 1.0) bad |= 8;
  double d = 2.0;
  long long l = reinterpret_cast<long long&>(d);   // a value read through the cast
  if (l != 0x4000000000000000ll) bad |= 16;
  std::printf("%x %llx %d\n", as_bits(1.0f), (unsigned long long)as_bits(2.0), bad);
  return bad == 0 ? 5 : bad;
}
