// EXPECT: 0
// __builtin_sycl_kernel_param_count(KernelIdentity<K>()): the number of kernel parameters of K, its non-static data members.
// docs/notes/sycl-kernel-builtins.md. The namespace below is the oneAPI headers' sycl::_V1::detail (lambda captures are not
// covered yet: their closure fields are created lazily).
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };
struct Empty {};
struct Three { int a; int b; int c; };

int main() {
  if (__builtin_sycl_kernel_param_count(sycl::_V1::detail::KernelIdentity<Two>()) != 2) return 1;
  if (__builtin_sycl_kernel_param_count(sycl::_V1::detail::KernelIdentity<Empty>()) != 0) return 2;
  if (__builtin_sycl_kernel_param_count(sycl::_V1::detail::KernelIdentity<Three>()) != 3) return 3;
  return 0;
}
