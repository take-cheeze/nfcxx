// EXPECT: 0
// __builtin_sycl_kernel_column_number(KernelIdentity<K>()): the column of K's declaration (the position of its name).
namespace sycl { inline namespace _V1 { namespace detail {
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct Two { int a; double b; };
   struct Indented { int a; };

int main() {
  if (__builtin_sycl_kernel_column_number(sycl::_V1::detail::KernelIdentity<Two>()) != 8) return 1;
  if (__builtin_sycl_kernel_column_number(sycl::_V1::detail::KernelIdentity<Indented>()) != 11) return 2;
  return 0;
}
