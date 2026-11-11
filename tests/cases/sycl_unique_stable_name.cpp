// EXPECT: 0
// __builtin_sycl_unique_stable_name(T): a const char pointer to the mangled name of T (the SYCL kernel-support builtin used by
// the oneAPI headers, docs/notes/sycl-kernel-builtins.md). Equal types give equal names, distinct types distinct names, and a
// template-dependent type is folded when the template is instantiated.
#include <cstring>

struct A { int x; };
struct B { int x; };

template <class T> const char *name_of() { return __builtin_sycl_unique_stable_name(T); }

int main() {
  const char *a = __builtin_sycl_unique_stable_name(A);
  const char *b = __builtin_sycl_unique_stable_name(B);
  if (a == nullptr || a[0] == '\0') return 1;
  if (std::strcmp(a, __builtin_sycl_unique_stable_name(A)) != 0) return 2;
  if (std::strcmp(a, b) == 0) return 3;
  if (std::strcmp(name_of<A>(), a) != 0) return 4;
  if (std::strcmp(name_of<B>(), b) != 0) return 5;
  if (std::strcmp(name_of<int>(), __builtin_sycl_unique_stable_name(int)) != 0) return 6;
  if (std::strcmp(name_of<int>(), name_of<A>()) == 0) return 7;
  return 0;
}
