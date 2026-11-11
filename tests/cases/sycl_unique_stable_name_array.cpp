// EXPECT: 0
// __builtin_sycl_unique_stable_name(T) is a character array, const char[N] with the terminating null, as the oneAPI headers'
// KernelInfoImpl uses it: it indexes the name and takes its length as a template argument (docs/notes/sycl-kernel-builtins.md).
// `auto n` decays it to a pointer to the first character, which is what KernelInfoImpl indexes.
#include <cstring>

struct A { int x; };

template <class T> struct Q {
  static constexpr auto n = __builtin_sycl_unique_stable_name(T);
  static constexpr unsigned long len = __builtin_strlen(n);
};

static_assert(Q<A>::n[Q<A>::len] == '\0', "null-terminated");
static_assert(Q<A>::n[1] == 'A', "mangled name of A");

int main() {
  if (std::strcmp(Q<A>::n, __builtin_sycl_unique_stable_name(A)) != 0) return 1;
  return 0;
}
