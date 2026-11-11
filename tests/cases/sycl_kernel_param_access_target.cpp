// EXPECT: 0
// __builtin_sycl_kernel_param_access_target(KernelIdentity<K>(), I): the access target of an accessor parameter. Only
// accessors have one (accessor captures are not supported yet), so for a standard-layout parameter the value is 0.
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };

int main() {
  if (__builtin_sycl_kernel_param_access_target(sycl::_V1::detail::KernelIdentity<Two>(), 0) != 0) return 1;
  if (__builtin_sycl_kernel_param_access_target(sycl::_V1::detail::KernelIdentity<Two>(), 1) != 0) return 2;
  return 0;
}
