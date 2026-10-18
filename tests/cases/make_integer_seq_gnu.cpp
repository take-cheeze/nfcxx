// EXPECT: 0
// __make_integer_seq is a builtin template only in the SYCL pass (__SYCL_UNNAMED_LAMBDA__ on the command line, as the real
// toolchain defines it): <sycl/detail/kernel_desc.hpp> needs it there. An ordinary GNU-mode translation unit does not get it.
#if __has_builtin(__make_integer_seq)
#error __make_integer_seq must not be a builtin outside the SYCL pass
#endif
int main() { return 0; }
