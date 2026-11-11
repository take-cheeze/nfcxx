// EXPECT: 0
// __builtin_sycl_kernel_line_number(KernelIdentity<K>()): the line of K's declaration.
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };
struct Later { int a; };

int main() {
  if (__builtin_sycl_kernel_line_number(sycl::_V1::detail::KernelIdentity<Two>()) != 7) return 1;
  if (__builtin_sycl_kernel_line_number(sycl::_V1::detail::KernelIdentity<Later>()) != 8) return 2;
  return 0;
}
