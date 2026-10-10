// nfcxx exception shim: libstdc++'s exceptions for programs compiled by EDG.
//
// EDG lowers C++ exceptions to its own setjmp/longjmp ABI and runtime (libC.a: __throw_setup, __throw, the EH stack).
// libstdc++.so throws with the Itanium ABI (__cxa_throw, the system unwinder), and a try block of EDG-compiled code
// never sees such an exception: the program ends in terminate. This file is compiled by nfcxx itself (EDG front end,
// so every `throw` below is an EDG throw) and linked into every hosted program ahead of libstdc++, which makes the
// executable's definitions win over the library's, including for calls made from inside libstdc++.so:
//
//   - the std::__throw_* functions of <bits/functexcept.h> (vector::at, std::stoi, std::function, string::_M_create...)
//     throw the same classes, with the same messages, through EDG's runtime;
//   - std::exception_ptr, std::current_exception, std::rethrow_exception and (through them) std::nested_exception,
//     std::throw_with_nested, std::make_exception_ptr, std::promise/future errors work on EDG exceptions.
//
// exception_ptr needs the runtime to keep an exception alive after its handler ends. EDG's runtime has no such thing;
// the fork take-cheeze/edg-compiler adds __eh_pin_current, __eh_make_detached, __eh_pin, __eh_unpin, __eh_pinned_*,
// __eh_rethrow_pinned to lib_src/throw.c (the references below are weak). With an older libC.a the __throw_*
// functions still work, std::current_exception returns an empty exception_ptr and std::make_exception_ptr too.
//
// Limits (docs/notes/pathb-hosted.md, "Exceptions thrown by libstdc++"): an exception thrown by gcc-compiled code
// with __cxa_throw directly (not through a __throw_* function) is not caught; the longjmp EDG performs skips the
// destructors of libstdc++'s own frames; std::uncaught_exceptions is the library's (always 0).

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <functional>
#include <future>
#include <ios>
#include <new>
#include <regex>
#include <stdexcept>
#include <system_error>
#include <typeinfo>
#include <typeindex>

#include <cxxabi.h>

#include <dlfcn.h>

#ifdef __GLIBCXX__

namespace std
{
  // --- the __throw_* functions ------------------------------------------------------------------------------------

  void __throw_bad_exception() { throw bad_exception(); }
  void __throw_bad_alloc() { throw bad_alloc(); }
  void __throw_bad_array_new_length() { throw bad_array_new_length(); }
  void __throw_bad_cast() { throw bad_cast(); }
  void __throw_bad_typeid() { throw bad_typeid(); }
  void __throw_logic_error(const char* s) { throw logic_error(s); }
  void __throw_domain_error(const char* s) { throw domain_error(s); }
  void __throw_invalid_argument(const char* s) { throw invalid_argument(s); }
  void __throw_length_error(const char* s) { throw length_error(s); }
  void __throw_out_of_range(const char* s) { throw out_of_range(s); }
  void __throw_runtime_error(const char* s) { throw runtime_error(s); }
  void __throw_range_error(const char* s) { throw range_error(s); }
  void __throw_overflow_error(const char* s) { throw overflow_error(s); }
  void __throw_underflow_error(const char* s) { throw underflow_error(s); }

  // libstdc++ formats into a buffer of strlen(fmt) + 512 bytes; the messages are far shorter than that.
  void __throw_out_of_range_fmt(const char* fmt, ...)
  {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    throw out_of_range(buf);
  }

  void __throw_ios_failure(const char* s) { throw ios_base::failure(s); }
  void __throw_ios_failure(const char* s, int e)
  {
    throw ios_base::failure(s, error_code(e, generic_category()));
  }
  void __throw_system_error(int e) { throw system_error(error_code(e, generic_category())); }
  void __throw_future_error(int e) { throw future_error(make_error_code(future_errc(e))); }
  void __throw_bad_function_call() { throw bad_function_call(); }
  void __throw_regex_error(regex_constants::error_type e) { throw regex_error(e); }
}  // namespace std

// --- exception_ptr --------------------------------------------------------------------------------------------------
//
// An exception_ptr holds a handle of EDG's runtime (the address of the exception's primary throw entry); the header's
// inline members call _M_addref/_M_release, which are the ones defined here.

extern "C"
{
  // EDG runtime hooks (lib_src/throw.c of take-cheeze/edg-compiler); weak so that an older libC.a still links.
  void* __eh_pin_current(void) __attribute__((weak));
  void* __eh_make_detached(const std::type_info*, void (*)(void*), int, int*, void*, void (*)(void*))
      __attribute__((weak));
  void __eh_pin(void*) __attribute__((weak));
  void __eh_unpin(void*) __attribute__((weak));
  void* __eh_pinned_object(void*) __attribute__((weak));
  const std::type_info* __eh_pinned_type(void*) __attribute__((weak));
  void __eh_rethrow_pinned(void*) __attribute__((weak));
}

namespace
{
  const int ets_pointer = 0x01;  // ETS_IS_POINTER, ETS_CONST, ETS_VOLATILE of lib_src/eh.h
  const int ets_const = 0x02;
  const int ets_volatile = 0x04;

  bool have_hooks() { return __eh_pin_current != nullptr; }

  // libstdc++'s own exception_ptr, for exceptions made by std::make_exception_ptr: the header allocates the object with
  // __cxa_allocate_exception and registers type and destructor with __cxa_init_primary_exception (both libstdc++'s own,
  // not replaced here), then asks exception_ptr(void*) to take it over. The library's exception_ptr keeps the
  // object's lifetime; the EDG runtime entry only refers to it and calls the library's release as its "destructor".
  struct lib_ptr { void* obj; };
  typedef void (*lib_ptr_fn)(lib_ptr*);
  typedef const std::type_info* (*lib_type_fn)(const lib_ptr*);

  void* next_symbol(const char* name)
  {
    void* f = dlsym(RTLD_NEXT, name);
    if (f == nullptr) {
      fprintf(stderr, "nfcxx: cannot find %s in libstdc++\n", name);
      abort();
    }
    return f;
  }

  void lib_release(void* obj)  // the "destructor" of a made exception: libstdc++'s exception_ptr::_M_release
  {
    static lib_ptr_fn f = reinterpret_cast<lib_ptr_fn>(next_symbol("_ZNSt15__exception_ptr13exception_ptr10_M_releaseEv"));
    lib_ptr p = {obj};
    f(&p);
  }
}  // namespace

namespace std
{
  namespace __exception_ptr
  {
    exception_ptr::exception_ptr(void* obj) noexcept : _M_exception_object(nullptr)
    {
      static lib_ptr_fn addref = reinterpret_cast<lib_ptr_fn>(next_symbol("_ZNSt15__exception_ptr13exception_ptr9_M_addrefEv"));
      static lib_type_fn type_of = reinterpret_cast<lib_type_fn>(next_symbol("_ZNKSt15__exception_ptr13exception_ptr20__cxa_exception_typeEv"));
      // Not the library's constructor: it calls _M_addref, which is the one defined below.
      lib_ptr held = {obj};
      addref(&held);  // a reference in the library's refcount, released by lib_release
      const type_info* t = type_of(&held);
      if (!have_hooks() || t == nullptr) {
        lib_release(obj);
        return;
      }
      // What the compiler passes to __throw_setup for a pointer: the type_info of the pointee, and the flags "pointer"
      // and the qualifiers of the pointee (lib_src/eh.h). The runtime calls no destructor for a pointer, so the block
      // goes back to the library through the free function instead. Multi-level pointers and pointers to members would
      // need the runtime's ptr_flags array: not described, the exception_ptr stays empty.
      int flags = 0;
      const bool pointer = t->name()[0] == 'P';
      if (pointer) {
        const abi::__pbase_type_info* pb = static_cast<const abi::__pbase_type_info*>(t);
        const char c = pb->__pointee->name()[0];
        if (c == 'P' || c == 'M') {
          lib_release(obj);
          return;
        }
        flags = ets_pointer;
        if (pb->__flags & abi::__pbase_type_info::__const_mask) flags |= ets_const;
        if (pb->__flags & abi::__pbase_type_info::__volatile_mask) flags |= ets_volatile;
        t = pb->__pointee;
      } else if (t->name()[0] == 'M') {   // pointer to member
        lib_release(obj);
        return;
      }
      _M_exception_object = __eh_make_detached(t, pointer ? nullptr : lib_release, flags, nullptr, obj,
                                               pointer ? lib_release : nullptr);
    }

    void exception_ptr::_M_addref() noexcept { __eh_pin(_M_exception_object); }
    void exception_ptr::_M_release() noexcept { __eh_unpin(_M_exception_object); }
    void* exception_ptr::_M_get() const noexcept { return __eh_pinned_object(_M_exception_object); }
    const type_info* exception_ptr::__cxa_exception_type() const noexcept
    {
      return _M_exception_object ? __eh_pinned_type(_M_exception_object) : nullptr;
    }
  }  // namespace __exception_ptr

  exception_ptr current_exception() noexcept
  {
    exception_ptr r;
    if (have_hooks()) r._M_exception_object = __eh_pin_current();
    return r;
  }

  void rethrow_exception(exception_ptr p)
  {
    if (p._M_exception_object == nullptr || !have_hooks()) terminate();
    __eh_rethrow_pinned(p._M_exception_object);
    terminate();
  }
}  // namespace std

#endif  // __GLIBCXX__
