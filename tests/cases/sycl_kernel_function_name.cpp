// EXPECT: 0
// __builtin_sycl_kernel_function_name(KernelIdentity<K>()): the name of the function a kernel is declared in. Not recorded
// yet: the value is the empty string (docs/notes/sycl-kernel-builtins.md). Taken in a constant expression, as the oneAPI
// headers do.
namespace sycl { inline namespace _V1 { namespace detail {
struct string_view { const char *str = nullptr; unsigned long len = 0; };
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct K1 { int a; };

constexpr sycl::_V1::detail::string_view fn1 = __builtin_sycl_kernel_function_name(sycl::_V1::detail::KernelIdentity<K1>());

int main() {
  if (fn1.str == nullptr) return 1;
  if (fn1.str[0] != '\0' || fn1.len != 0) return 2;
  return 0;
}
