// EXPECT: 0
// A default member initializer that captures this and reads a member, in an aggregate whose earlier element is built by a
// constructor call. That constructor's constant-evaluation branch runs a loop (its block ends before the initializer runs),
// as libstdc++'s char_traits::length does for std::string_view. The this pointer must stay valid; it used to expire ("attempt
// to access expired storage"). This is the shape of CompileTimeKernelInfoTy in <sycl/detail/compile_time_kernel_info.hpp>.
// No headers: the IR golden does not depend on the host library.
struct Traits {
  static constexpr unsigned long length(const char *s) {
    if (__builtin_is_constant_evaluated()) {
      unsigned long n = 0;
      while (s[n] != '\0')
        ++n;
      return n;
    }
    return __builtin_strlen(s);
  }
};

struct SV {
  const char *str = nullptr;
  unsigned long len = 0;
  constexpr SV() = default;
  constexpr SV(const char *s) noexcept : len{Traits::length(s)}, str{s} {}
};

struct Info {
  SV Name{};
  unsigned NumParams = 0;
  bool HasSpecialCaptures = [this]() constexpr {
    if (NumParams == 0)
      return true;
    return false;
  }();
};

template <class K> inline constexpr Info CI{SV("n"), 0};
constexpr auto ci = CI<int>;
static_assert(ci.HasSpecialCaptures, "a kernel with no parameters has special captures");
static_assert(ci.Name.len == 1, "the name is kept");

int main() { return ci.HasSpecialCaptures && ci.NumParams == 0 && ci.Name.len == 1 ? 0 : 1; }
