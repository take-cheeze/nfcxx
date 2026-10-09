// EXPECT: 0
// __is_base_of and __underlying_type.
struct B {};
struct D : B {};
struct P {};
struct Q : P {};
struct Other {};
enum class Small : unsigned char { V = 200 };
enum Plain : int { W = -1 };
enum Untyped { Z = 3 };

template <typename T, typename U> struct IsSame { static const bool value = false; };
template <typename T> struct IsSame<T, T> { static const bool value = true; };

int main() {
  int fails = 0;
  fails += !__is_base_of(B, D);
  fails += !__is_base_of(B, B);       // a class is its own base
  fails += !!__is_base_of(D, B);
  fails += !!__is_base_of(Other, D);
  fails += !!__is_base_of(B, int);
  // __underlying_type: checked via sizeof and the type identity of the result.
  fails += !IsSame<__underlying_type(Small), unsigned char>::value;
  fails += !IsSame<__underlying_type(Plain), int>::value;
  fails += !IsSame<__underlying_type(Untyped), unsigned int>::value;  // gcc/clang: unscoped enum w/o fixed type
  fails += (sizeof(__underlying_type(Small)) != 1);
  fails += (static_cast<int>(static_cast<__underlying_type(Plain)>(W)) != -1);
  fails += (static_cast<unsigned char>(Small::V) != 200);
  return fails;
}
