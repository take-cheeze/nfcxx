// EXPECT: 0
// __builtin_sycl_kernel_file_name(KernelIdentity<K>()): the file of K's declaration, a sycl::detail::string_view. It is checked at
// compile time (the value is a constant expression, as the oneAPI headers use it), and only for the file's own name, so the IR
// golden does not depend on the checkout directory. docs/notes/sycl-kernel-builtins.md.
namespace sycl { inline namespace _V1 { namespace detail {
struct string_view { const char *str = nullptr; unsigned long len = 0; };
template <typename KNT> struct KernelIdentity { using type = KNT; };
} } }

struct K1 { int a; };

constexpr bool ends_with(const char *s, const char *suffix) {
  unsigned long n = 0, m = 0;
  while (s[n] != '\0') ++n;
  while (suffix[m] != '\0') ++m;
  if (m > n) return false;
  for (unsigned long i = 0; i < m; ++i) {
    if (s[n - m + i] != suffix[i]) return false;
  }
  return true;
}

static_assert(ends_with(__builtin_sycl_kernel_file_name(sycl::_V1::detail::KernelIdentity<K1>()).str,
                        "sycl_kernel_file_name.cpp"),
              "kernel file name is the file of its declaration");

int main() { return 0; }
