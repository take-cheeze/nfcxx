// EXPECT: 0
// __builtin_bit_cast: round-trips and a constant-expression use.
struct Pair { unsigned lo, hi; };
constexpr unsigned long long kBits = __builtin_bit_cast(unsigned long long, Pair{1u, 2u});
static_assert(sizeof(kBits) == 8);

int main() {
  int fails = 0;
  float f = 1.0f;
  unsigned u = __builtin_bit_cast(unsigned, f);
  fails += u != 0x3f800000u;
  fails += __builtin_bit_cast(float, u) != 1.0f;
  double d = -0.0;
  fails += __builtin_bit_cast(unsigned long long, d) != 0x8000000000000000ull;
  fails += __builtin_bit_cast(Pair, kBits).lo != 1u;
  fails += __builtin_bit_cast(Pair, kBits).hi != 2u;
  return fails;
}
