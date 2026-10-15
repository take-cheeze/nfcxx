// EXPECT: 0
// <type_traits>: static_assert for every trait, plus runtime checks through integral_constant.
#include <type_traits>

struct Empty {};
struct NonEmpty { int x; };
struct Final final {};
struct Base {};
struct Derived : Base {};
union U { int i; float f; };
enum Color { Red };
enum class Big : long long { X };
struct Triv { int a; };
struct DtorX { ~DtorX() {} };
struct CopyCtor { CopyCtor(const CopyCtor&) {} int a; };
struct Ctor2 { Ctor2(int, int) {} };

static_assert(std::is_same<int, int>::value);
static_assert(!std::is_same<int, const int>::value);
static_assert(std::is_same_v<const int, const int>);
static_assert(std::is_class<NonEmpty>::value && !std::is_class<U>::value);
static_assert(!std::is_class<int>::value && std::is_union<U>::value && !std::is_union<NonEmpty>::value);
static_assert(std::is_enum<Color>::value && std::is_enum<Big>::value && !std::is_enum<Empty>::value);
static_assert(std::is_empty<Empty>::value && !std::is_empty<NonEmpty>::value);
static_assert(std::is_final<Final>::value && !std::is_final<Base>::value);
static_assert(std::is_pod<NonEmpty>::value && !std::is_pod<CopyCtor>::value);
static_assert(std::is_base_of<Base, Derived>::value && std::is_base_of<Base, Base>::value);
static_assert(!std::is_base_of<Derived, Base>::value);
static_assert(std::is_trivially_copyable<Triv>::value && !std::is_trivially_copyable<CopyCtor>::value);
static_assert(std::is_trivially_destructible<Triv>::value && !std::is_trivially_destructible<DtorX>::value);
static_assert(std::is_constructible<Ctor2, int, int>::value && !std::is_constructible<Ctor2, int>::value);
static_assert(std::is_constructible<int, long>::value);
static_assert(std::is_trivially_constructible<Triv>::value);
static_assert(std::is_same<std::underlying_type_t<Big>, long long>::value);
static_assert(std::is_integral<std::underlying_type_t<Color>>::value);  // implementation-defined type

static_assert(std::is_void<void>::value && std::is_void<const void>::value && !std::is_void<int>::value);
static_assert(std::is_integral<bool>::value && std::is_integral<const unsigned long>::value);
static_assert(!std::is_integral<float>::value && std::is_floating_point<double>::value);
static_assert(std::is_arithmetic<char>::value && !std::is_arithmetic<Empty>::value);
static_assert(std::is_pointer<int*>::value && !std::is_pointer<int>::value);
static_assert(std::is_lvalue_reference<int&>::value && std::is_rvalue_reference<int&&>::value);
static_assert(std::is_reference<int&>::value && !std::is_reference<int>::value);
static_assert(std::is_const<const int>::value && std::is_volatile<volatile int>::value);
static_assert(std::is_array<int[3]>::value && !std::is_array<int>::value);

static_assert(std::is_same<std::remove_const_t<const int>, int>::value);
static_assert(std::is_same<std::remove_volatile_t<volatile int>, int>::value);
static_assert(std::is_same<std::remove_cv_t<const volatile int>, int>::value);
static_assert(std::is_same<std::remove_reference_t<int&>, int>::value);
static_assert(std::is_same<std::remove_reference_t<int&&>, int>::value);
static_assert(std::is_same<std::add_const_t<int>, const int>::value);
static_assert(std::is_same<std::add_pointer_t<int&>, int*>::value);
static_assert(std::is_same<std::decay_t<const int&>, int>::value);
static_assert(std::is_same<std::decay_t<int[4]>, int*>::value);
static_assert(std::is_same<std::conditional_t<true, int, long>, int>::value);
static_assert(std::is_same<std::conditional_t<false, int, long>, long>::value);
static_assert(std::is_same<std::enable_if_t<true, char>, char>::value);
static_assert(std::conjunction<std::true_type, std::true_type>::value);
static_assert(!std::conjunction<std::true_type, std::false_type>::value);
static_assert(std::disjunction<std::false_type, std::true_type>::value);
static_assert(std::negation<std::false_type>::value);

int main() {
  // The traits are constant, so a wrong answer shows up as a nonzero exit code.
  int fails = 0;
  fails += !std::is_class<NonEmpty>::value;
  fails += std::is_union<NonEmpty>::value;
  fails += !std::is_empty<Empty>::value;
  fails += !std::is_trivially_copyable<Triv>::value;
  fails += std::is_trivially_copyable<CopyCtor>::value;
  fails += !std::is_base_of<Base, Derived>::value;
  fails += !std::is_same<std::underlying_type_t<Big>, long long>::value;
  fails += std::is_same<std::decay_t<int[2]>, int[2]>::value;
  std::integral_constant<int, 42> ic;
  fails += ic.value != 42;
  fails += static_cast<int>(ic) != 42;
  fails += std::bool_constant<false>::value;
  return fails;
}
