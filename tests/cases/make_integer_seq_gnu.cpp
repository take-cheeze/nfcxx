// EXPECT: 0
// __make_integer_seq is a builtin template only in the SYCL pass (__SYCL_UNNAMED_LAMBDA__ on the command line, as the real
// toolchain defines it): <sycl/detail/kernel_desc.hpp> needs it there. The check applies where it means something: a host
// that has __has_builtin and is not clang-mode (EDG's clang mode, the macOS and clang hosts, creates __make_integer_seq for
// every translation unit, so there the case checks nothing). Hosts without __has_builtin (hexagon) skip the check too.
#if defined(__has_builtin) && !defined(__clang__)
#if __has_builtin(__make_integer_seq)
#error __make_integer_seq must not be a builtin outside the SYCL pass
#endif
#endif
int main() { return 0; }
