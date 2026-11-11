// EXPECT: 0
// __builtin_sycl_kernel_param_size(KernelIdentity<K>(), I): the size in bytes of parameter I (its data member) of K.
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };

int main() {
  if (__builtin_sycl_kernel_param_size(sycl::_V1::detail::KernelIdentity<Two>(), 0) != (int)sizeof(int)) return 1;
  if (__builtin_sycl_kernel_param_size(sycl::_V1::detail::KernelIdentity<Two>(), 1) != (int)sizeof(double)) return 2;
  return 0;
}
