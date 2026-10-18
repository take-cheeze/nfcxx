// EXPECT: 2
// An empty expansion of a fold over an operator with no identity value (here +) is ill-formed, but in a substitution
// context (a default template argument during deduction) it is a deduction failure, not a hard error: the non-template
// overload is chosen. This is the shape of sycl::vec's variadic constructor (sycl/vector.hpp).
#include <type_traits>

struct A {
  static constexpr int value = 0;
};

template <typename... T, typename = std::enable_if_t<(T::value + ...) == 0>>
int pick(T...) {
  return 1;
}

int pick() { return 2; }

int main() { return pick(); }
