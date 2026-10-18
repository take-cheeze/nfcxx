// EXPECT: 0
// __builtin_sycl_kernel_file_name(KernelIdentity<K>()): the file of K's declaration, a sycl::detail::string_view (taken in a
// constant expression, as the oneAPI headers do). docs/notes/sycl-kernel-builtins.md.
#include <cstring>

namespace sycl { inline namespace _V1 { namespace detail {
struct string_view { const char *str = nullptr; unsigned long len = 0; };
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct K1 { int a; };

constexpr sycl::_V1::detail::string_view file1 = __builtin_sycl_kernel_file_name(sycl::_V1::detail::KernelIdentity<K1>());

int main() {
  if (file1.str == nullptr) return 1;
  if (std::strcmp(file1.str, __FILE__) != 0) return 2;
  return 0;
}
