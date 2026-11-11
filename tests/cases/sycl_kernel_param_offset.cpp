// EXPECT: 0
// __builtin_sycl_kernel_param_offset(KernelIdentity<K>(), I): the byte offset of parameter I (its data member) in K.
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };

int main() {
  if (__builtin_sycl_kernel_param_offset(sycl::_V1::detail::KernelIdentity<Two>(), 0) != 0) return 1;
  if (__builtin_sycl_kernel_param_offset(sycl::_V1::detail::KernelIdentity<Two>(), 1) != 8) return 2;
  return 0;
}
