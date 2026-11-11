// EXPECT: 42
// A reinterpret_cast whose target is a dependent member alias template of a dependent class
// (backend_traits<B>::return_type<T>, as sycl/backend.hpp uses for get_native). The prototype
// instantiation sees the target as a dependent class; the cast is checked again when the
// template is instantiated, where it is a pointer.
struct handle { int x; };
template <int B, class T> struct BackendReturn { using type = int *; };
template <int B> class backend_traits {
public:
  template <class T> using return_type = typename BackendReturn<B, T>::type;
};
template <int B, class T> using backend_return_t = typename backend_traits<B>::template return_type<T>;

struct Obj { void *p; };

template <int B, class S>
typename backend_traits<B>::template return_type<S> get_native(const S &o) {
  return reinterpret_cast<typename backend_traits<B>::template return_type<S>>(o.p);
}
template <int B, class S>
backend_return_t<B, S> get_native_alias(const S &o) {
  return reinterpret_cast<backend_return_t<B, S>>(o.p);
}

int main() {
  int v = 40;
  Obj o{&v};
  int *a = get_native<1>(o);
  int *b = get_native_alias<1>(o);
  return (*a == 40 && *b == 40) ? 42 : 1;
}
