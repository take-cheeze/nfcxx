// EXPECT: 0
// A default member initializer that captures this and reads a member, in an aggregate whose earlier element is built by a
// constructor call (std::string_view("n") runs a constexpr function with local blocks). The this pointer must stay valid
// after that constructor's block ends; it used to expire ("attempt to access expired storage"). This is the shape of
// CompileTimeKernelInfoTy in <sycl/detail/compile_time_kernel_info.hpp>.
#include <string_view>

struct Info {
  std::string_view Name{};
  unsigned NumParams = 0;
  bool HasSpecialCaptures = [this]() constexpr {
    if (NumParams == 0)
      return true;
    return false;
  }();
};

template <class K> inline constexpr Info CI{std::string_view("n"), 0};
constexpr auto ci = CI<int>;
static_assert(ci.HasSpecialCaptures, "a kernel with no parameters has special captures");
static_assert(ci.Name == std::string_view("n"), "the name is kept");

int main() { return ci.HasSpecialCaptures && ci.NumParams == 0 ? 0 : 1; }
