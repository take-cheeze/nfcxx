// Type-trait builtins that cosmo's libc++ (cosmocc 4.0.2) uses and EDG's g++ mode does not provide. Pre-included for
// Path B programs built with --cosmo (docs/notes/cosmo.md); a template maps each name to a constant. C++ only.
#ifndef NFCXX_COSMO_LIBCXX_TRAITS_H
#define NFCXX_COSMO_LIBCXX_TRAITS_H
#ifdef __cplusplus

namespace nfcxx_cosmo {
template <class T> struct is_reference { static constexpr bool value = false; };
template <class T> struct is_reference<T&> { static constexpr bool value = true; };
template <class T> struct is_reference<T&&> { static constexpr bool value = true; };

template <class T> struct is_function { static constexpr bool value = false; };
template <class R, class... A> struct is_function<R(A...)> { static constexpr bool value = true; };
template <class R, class... A> struct is_function<R(A..., ...)> { static constexpr bool value = true; };

template <class T> struct is_void { static constexpr bool value = false; };
template <> struct is_void<void> { static constexpr bool value = true; };

template <class T> struct is_object {
  static constexpr bool value = !is_function<T>::value && !is_reference<T>::value && !is_void<T>::value;
};


template <class T> struct is_array { static constexpr bool value = false; };
template <class T, unsigned long N> struct is_array<T[N]> { static constexpr bool value = true; };
template <class T> struct is_array<T[]> { static constexpr bool value = true; };
template <class T> struct is_pointer { static constexpr bool value = false; };
template <class T> struct is_pointer<T*> { static constexpr bool value = true; };
template <class T> struct is_pointer<T* const> { static constexpr bool value = true; };
template <class T> struct is_pointer<T* volatile> { static constexpr bool value = true; };
template <class T> struct is_pointer<T* const volatile> { static constexpr bool value = true; };
template <class T> struct is_member_object_pointer { static constexpr bool value = false; };
template <class T, class C> struct is_member_object_pointer<T C::*> { static constexpr bool value = !is_function<T>::value; };
template <class T> struct is_member_function_pointer { static constexpr bool value = false; };
template <class T, class C> struct is_member_function_pointer<T C::*> { static constexpr bool value = is_function<T>::value; };
template <class T> struct is_member_pointer {
  static constexpr bool value = is_member_object_pointer<T>::value || is_member_function_pointer<T>::value;
};
template <class T> struct is_lvalue_reference { static constexpr bool value = false; };
template <class T> struct is_lvalue_reference<T&> { static constexpr bool value = true; };
template <class T> struct is_rvalue_reference { static constexpr bool value = false; };
template <class T> struct is_rvalue_reference<T&&> { static constexpr bool value = true; };
template <class T> struct is_const { static constexpr bool value = false; };
template <class T> struct is_const<const T> { static constexpr bool value = true; };
template <class T> struct is_volatile { static constexpr bool value = false; };
template <class T> struct is_volatile<volatile T> { static constexpr bool value = true; };
template <class T> struct is_referenceable { static constexpr bool value = !is_void<T>::value && !is_reference<T>::value; };

char scoped_enum_probe(int);
long scoped_enum_probe(...);
template <class T> T& scoped_enum_decl();
template <class T> struct is_scoped_enum {
  static constexpr bool value = __is_enum(T) && sizeof(scoped_enum_probe(scoped_enum_decl<T>())) != sizeof(char);
};
}  // namespace nfcxx_cosmo

#define __is_reference(T) (::nfcxx_cosmo::is_reference<T>::value)
#define __is_object(T) (::nfcxx_cosmo::is_object<T>::value)
#define __is_scoped_enum(T) (::nfcxx_cosmo::is_scoped_enum<T>::value)
#define __is_array(T) (::nfcxx_cosmo::is_array<T>::value)
#define __is_pointer(T) (::nfcxx_cosmo::is_pointer<T>::value)
#define __is_member_pointer(T) (::nfcxx_cosmo::is_member_pointer<T>::value)
#define __is_member_object_pointer(T) (::nfcxx_cosmo::is_member_object_pointer<T>::value)
#define __is_member_function_pointer(T) (::nfcxx_cosmo::is_member_function_pointer<T>::value)
#define __is_lvalue_reference(T) (::nfcxx_cosmo::is_lvalue_reference<T>::value)
#define __is_rvalue_reference(T) (::nfcxx_cosmo::is_rvalue_reference<T>::value)
#define __is_const(T) (::nfcxx_cosmo::is_const<T>::value)
#define __is_volatile(T) (::nfcxx_cosmo::is_volatile<T>::value)
#define __is_referenceable(T) (::nfcxx_cosmo::is_referenceable<T>::value)

// the Clang builtin template: the I-th type of a pack
namespace nfcxx_cosmo {
template <unsigned long I, class... Ts> struct pack_element;
template <class T, class... Ts> struct pack_element<0, T, Ts...> { using type = T; };
template <unsigned long I, class T, class... Ts> struct pack_element<I, T, Ts...> {
  using type = typename pack_element<I - 1, Ts...>::type;
};
}  // namespace nfcxx_cosmo
template <unsigned long I, class... Ts>
using __type_pack_element = typename ::nfcxx_cosmo::pack_element<I, Ts...>::type;

#endif  // __cplusplus
#endif
