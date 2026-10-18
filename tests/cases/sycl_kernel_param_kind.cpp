// EXPECT: 0
// __builtin_sycl_kernel_param_kind(KernelIdentity<K>(), I): the kernel_param_kind_t of parameter I of K (a standard-layout
// object is kind_std_layout, a pointer kind_pointer). The result type is sycl::detail::kernel_param_kind_t, which the oneAPI
// headers assign to an enum class object. docs/notes/sycl-kernel-builtins.md. (An index that is not a constant is not
// supported yet: the C back end no longer has the parameters by then.)
namespace sycl { inline namespace _V1 { namespace detail {
enum class kernel_param_kind_t { kind_accessor = 0, kind_std_layout = 1, kind_sampler = 2, kind_pointer = 3 };
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct P { int a; int *p; };

int main() {
  using sycl::_V1::detail::kernel_param_kind_t;
  kernel_param_kind_t k0 = __builtin_sycl_kernel_param_kind(sycl::_V1::detail::KernelIdentity<P>(), 0);
  kernel_param_kind_t k1 = __builtin_sycl_kernel_param_kind(sycl::_V1::detail::KernelIdentity<P>(), 1);
  if (k0 != kernel_param_kind_t::kind_std_layout) return 1;
  if (k1 != kernel_param_kind_t::kind_pointer) return 2;
  return 0;
}
