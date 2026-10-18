// EXPECT: 0
// __builtin_sycl_kernel_name(KernelIdentity<K>()): the kernel name, a sycl::detail::string_view of the mangled name of K (the
// same string __builtin_sycl_unique_stable_name gives). It is a class value, so it is taken in a constant expression, as the
// oneAPI headers do (CompileTimeKernelInfo). docs/notes/sycl-kernel-builtins.md.
#include <cstring>

namespace sycl { inline namespace _V1 { namespace detail {
struct string_view { const char *str = nullptr; unsigned long len = 0; };
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct K1 { int a; };
struct K2 { int a; };

constexpr sycl::_V1::detail::string_view name1 = __builtin_sycl_kernel_name(sycl::_V1::detail::KernelIdentity<K1>());
constexpr sycl::_V1::detail::string_view name2 = __builtin_sycl_kernel_name(sycl::_V1::detail::KernelIdentity<K2>());

int main() {
  if (name1.str == nullptr || name1.len == 0) return 1;
  if (std::strcmp(name1.str, __builtin_sycl_unique_stable_name(K1)) != 0) return 2;
  if (std::strcmp(name2.str, __builtin_sycl_unique_stable_name(K2)) != 0) return 3;
  if (std::strcmp(name1.str, name2.str) == 0) return 4;
  return 0;
}
