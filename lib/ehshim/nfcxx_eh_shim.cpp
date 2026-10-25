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
//   - __cxa_throw and __cxa_rethrow: a plain `throw` of gcc-compiled code (libstdc++, libtorch) reaches a handler of
//     EDG-compiled code when that handler would get it first (below);
//   - the vtables of the type_info classes are libstdc++'s, for the type_info objects libC.a defines.
//
// Limits (docs/notes/eh-shim.md): the longjmp EDG performs skips the destructors of gcc-compiled frames (unless
// NFCXX_EH_UNWIND=1); std::uncaught_exceptions is the library's.

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

#include <stdint.h>
#include <unwind.h>

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
  void* __eh_find_destination(const std::type_info*, int, void*) __attribute__((weak));
  void __eh_throw_detached(void*) __attribute__((noreturn, weak));
  extern int __nfcxx_eh_unwind_frames __attribute__((weak));  // lib/ehshim/nfcxx_eh_unwind.h
}

namespace
{
  const int ets_pointer = 0x01;  // ETS_IS_POINTER, ETS_CONST, ETS_VOLATILE of lib_src/eh.h
  const int ets_const = 0x02;
  const int ets_volatile = 0x04;

  bool have_hooks() { return __eh_pin_current != nullptr; }

  // The header libstdc++ puts before a thrown object (unwind-cxx.h): __cxa_exception, and __cxa_dependent_exception
  // (std::rethrow_exception's), whose first member is the primary object instead of the type. Both end with the
  // unwinder's header, and a primary one sits in __cxa_refcounted_exception after its reference count; the IA-64 ABI
  // fixes the layout. __cxa_eh_globals starts with the caught exceptions. The shim works on these directly instead of
  // calling libstdc++'s exception_ptr members or its __cxa_throw: the program's definitions of those win (this file's),
  // and in a program bundled with its libraries (--bundle-libs) dlsym(RTLD_NEXT) finds nothing after the executable.
  struct cxa_header {
    void* type_or_primary;
    void (*destructor)(void*);
    void (*unexpected)();
    void (*terminate)();
    cxa_header* next;
    int handler_count;
    int handler_switch_value;
    const unsigned char* action_record;
    const unsigned char* lsda;
    uintptr_t catch_temp;
    void* adjusted_ptr;
    _Unwind_Exception unwind;
  };
  struct cxa_refcounted { int count; cxa_header exc; };
  struct cxa_globals { cxa_header* caught; unsigned int uncaught; };
  static_assert(sizeof(cxa_header) == 112 && sizeof(cxa_refcounted) == 128, "libstdc++'s __cxa_exception on LP64");
  const uint64_t gxx_class = 0x474e5543432b2b00ull;            // "GNUCC++\0"
  const uint64_t gxx_dependent_class = 0x474e5543432b2b01ull;  // "GNUCC++\x01"

  cxa_header* header_of(void* obj) { return reinterpret_cast<cxa_header*>(obj) - 1; }
  int* refcount_of(void* obj) { return &reinterpret_cast<cxa_refcounted*>(reinterpret_cast<char*>(header_of(obj)) - 16)->count; }
  cxa_globals* library_globals() { return reinterpret_cast<cxa_globals*>(abi::__cxa_get_globals()); }

  // For exceptions made by std::make_exception_ptr and for those of gcc-compiled throws: the object was allocated by
  // __cxa_allocate_exception and initialized by __cxa_init_primary_exception. The EDG runtime entry holds one reference
  // in the library's count, and its "destructor" is this release, as libstdc++'s __cxa_decrement_exception_refcount.
  void lib_addref(void* obj) { __atomic_add_fetch(refcount_of(obj), 1, __ATOMIC_ACQ_REL); }
  void lib_release(void* obj)
  {
    if (__atomic_sub_fetch(refcount_of(obj), 1, __ATOMIC_ACQ_REL) == 0) {
      if (header_of(obj)->destructor != nullptr) header_of(obj)->destructor(obj);
      abi::__cxa_free_exception(obj);
    }
  }
  const std::type_info* lib_type(void* obj) { return static_cast<const std::type_info*>(header_of(obj)->type_or_primary); }

  // How the EDG runtime describes the type of a thrown object: what the compiler passes to __throw_setup for a pointer
  // is the type_info of the pointee, and the flags "pointer" and the qualifiers of the pointee (lib_src/eh.h). Multi-level
  // pointers and pointers to members would need the runtime's ptr_flags array: not described (false).
  bool describe_for_edg(const std::type_info* t, const std::type_info** edg_type, int* flags)
  {
    *flags = 0;
    *edg_type = t;
    if (t == nullptr || t->name()[0] == 'M') return false;
    if (t->name()[0] == 'P') {
      const abi::__pbase_type_info* pb = static_cast<const abi::__pbase_type_info*>(t);
      const char c = pb->__pointee->name()[0];
      if (c == 'P' || c == 'M') return false;
      *flags = ets_pointer;
      if (pb->__flags & abi::__pbase_type_info::__const_mask) *flags |= ets_const;
      if (pb->__flags & abi::__pbase_type_info::__volatile_mask) *flags |= ets_volatile;
      *edg_type = pb->__pointee;
    }
    return true;
  }

  // An EDG detached entry for an object of libstdc++ (allocated by __cxa_allocate_exception, initialized by
  // __cxa_init_primary_exception), or nullptr when the type cannot be described. The entry holds one reference in the
  // library's count, released by lib_release; the runtime calls no destructor for a pointer, so for one the block
  // goes back to the library through the free function instead.
  void* adopt_library_exception(void* obj)
  {
    lib_addref(obj);
    const std::type_info* t;
    int flags;
    if (!have_hooks() || !describe_for_edg(lib_type(obj), &t, &flags)) {
      lib_release(obj);
      return nullptr;
    }
    const bool pointer = flags & ets_pointer;
    return __eh_make_detached(t, pointer ? nullptr : lib_release, flags, nullptr, obj, pointer ? lib_release : nullptr);
  }
}  // namespace

namespace std
{
  namespace __exception_ptr
  {
    exception_ptr::exception_ptr(void* obj) noexcept : _M_exception_object(adopt_library_exception(obj)) {}

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

// --- __cxa_throw ----------------------------------------------------------------------------------------------------
//
// gcc-compiled code that throws with a plain `throw` (libtorch's c10::Error, the rest of libstdc++) calls __cxa_throw;
// the definition below wins over libstdc++'s as the __throw_* functions do. It gives the exception to EDG's runtime when
// a handler of EDG-compiled code would get it first, and to libstdc++'s __cxa_throw otherwise:
//   - the runtime names the EH stack entry at which its handler search would stop (__eh_find_destination): a try block
//     with a matching catch, or a noexcept or throw specification that ends in terminate. None: libstdc++'s.
//   - the entry lives in the frame of the EDG function that holds it, so the frames between the throw and that one are
//     those whose CFA is not above the entry. Each is asked as the unwinder's search phase asks it (its personality
//     routine, from its FDE, with _UA_SEARCH_PHASE). A handler there (a gcc-compiled catch, or a noexcept function,
//     which calls terminate) keeps the exception with libstdc++, and so does a stack that does not reach the entry
//     (another thread's: EDG's EH stack is a process global).
// Otherwise the object becomes a detached EDG entry, as for std::make_exception_ptr, thrown as a rethrow of it
// (__eh_throw_detached). These frames keep off EDG's EH stack (no local objects with destructors, no function-local
// statics): the library's unwinder leaves them when the library keeps the exception, and EDG's unwinder mode passes
// them without landing pads.
// The gcc-compiled frames in between are left by longjmp without their cleanups, except in NFCXX_EH_UNWIND=1 programs,
// where the unwinder runs them (docs/notes/eh-shim.md).
namespace
{
  typedef _Unwind_Reason_Code (*personality_fn)(int, _Unwind_Action, _Unwind_Exception_Class, _Unwind_Exception*,
                                                _Unwind_Context*);
  struct eh_bases { void* tbase; void* dbase; void* func; };  // struct dwarf_eh_bases of libgcc
}  // namespace

extern "C" const void* _Unwind_Find_FDE(void* pc, eh_bases* bases);  // libgcc (unwind-dw2-fde.h)

namespace
{

  uintptr_t read_uleb(const unsigned char** p)
  {
    uintptr_t v = 0;
    unsigned shift = 0;
    unsigned char b;
    do { b = *(*p)++; v |= (uintptr_t)(b & 0x7f) << shift; shift += 7; } while (b & 0x80);
    return v;
  }

  intptr_t read_sleb(const unsigned char** p)
  {
    intptr_t v = 0;
    unsigned shift = 0;
    unsigned char b;
    do { b = *(*p)++; v |= (intptr_t)(b & 0x7f) << shift; shift += 7; } while (b & 0x80);
    if (shift < 8 * sizeof v && (b & 0x40)) v |= -((intptr_t)1 << shift);
    return v;
  }

  // A DW_EH_PE-encoded pointer; false for an encoding not used for personality routines.
  bool read_encoded(unsigned char enc, const unsigned char** p, const eh_bases* bases, uintptr_t* out)
  {
    const unsigned char* start = *p;
    uintptr_t v;
    switch (enc & 0x0f) {
      case 0x00: { uintptr_t x; memcpy(&x, *p, sizeof x); *p += sizeof x; v = x; break; }
      case 0x01: v = read_uleb(p); break;
      case 0x02: { uint16_t x; memcpy(&x, *p, 2); *p += 2; v = x; break; }
      case 0x03: { uint32_t x; memcpy(&x, *p, 4); *p += 4; v = x; break; }
      case 0x04: { uint64_t x; memcpy(&x, *p, 8); *p += 8; v = (uintptr_t)x; break; }
      case 0x09: v = (uintptr_t)read_sleb(p); break;
      case 0x0a: { int16_t x; memcpy(&x, *p, 2); *p += 2; v = (uintptr_t)(intptr_t)x; break; }
      case 0x0b: { int32_t x; memcpy(&x, *p, 4); *p += 4; v = (uintptr_t)(intptr_t)x; break; }
      case 0x0c: { int64_t x; memcpy(&x, *p, 8); *p += 8; v = (uintptr_t)x; break; }
      default: return false;
    }
    switch (enc & 0x70) {
      case 0x00: break;
      case 0x10: v += (uintptr_t)start; break;
      case 0x20: v += (uintptr_t)bases->tbase; break;
      case 0x30: v += (uintptr_t)bases->dbase; break;
      case 0x40: v += (uintptr_t)bases->func; break;
      default: return false;
    }
    if (enc & 0x80) memcpy(&v, (const void*)v, sizeof v);  // DW_EH_PE_indirect
    *out = v;
    return true;
  }

  // The personality routine of the frame at ip, from the 'P' augmentation of its CIE, or nullptr.
  personality_fn frame_personality(uintptr_t ip)
  {
    eh_bases bases;
    const unsigned char* fde = static_cast<const unsigned char*>(_Unwind_Find_FDE((void*)ip, &bases));
    if (fde == nullptr) return nullptr;
    uint32_t len;
    int32_t cie_offset;
    memcpy(&len, fde, 4);
    if (len == 0xffffffffu) return nullptr;  // 64-bit DWARF: not produced for .eh_frame
    memcpy(&cie_offset, fde + 4, 4);
    const unsigned char* p = fde + 4 - cie_offset + 8;  // past the CIE's length and id
    const unsigned char version = *p++;
    const char* aug = reinterpret_cast<const char*>(p);
    p += strlen(aug) + 1;
    if (aug[0] != 'z') return nullptr;
    (void)read_uleb(&p);  // code alignment
    (void)read_sleb(&p);  // data alignment
    if (version == 1) p++; else (void)read_uleb(&p);  // return address register
    (void)read_uleb(&p);  // augmentation data length
    for (const char* a = aug + 1; *a; a++) {
      if (*a == 'P') {
        const unsigned char enc = *p++;
        uintptr_t routine;
        return read_encoded(enc, &p, &bases, &routine) ? reinterpret_cast<personality_fn>(routine) : nullptr;
      } else if (*a == 'L' || *a == 'R') {
        p++;
      } else if (*a != 'S' && *a != 'B') {
        return nullptr;
      }
    }
    return nullptr;
  }


  struct handler_search {
    uintptr_t edg_entry;      // the EH stack entry the EDG runtime would stop at
    _Unwind_Exception* exc;   // the object's header, initialized by __cxa_init_primary_exception
    int outcome;              // 0: walking, 1: EDG's handler first, 2: libstdc++'s (a handler here, or no EDG frame)
  };

  _Unwind_Reason_Code search_frame(_Unwind_Context* ctx, void* arg)
  {
    handler_search* s = static_cast<handler_search*>(arg);
    if (_Unwind_GetCFA(ctx) > s->edg_entry) {
      s->outcome = 1;
      return _URC_NORMAL_STOP;
    }
    int before = 0;
    uintptr_t ip = _Unwind_GetIPInfo(ctx, &before);
    if (ip == 0) return _URC_NO_REASON;
    personality_fn pers = frame_personality(before ? ip : ip - 1);
    if (pers == nullptr) return _URC_NO_REASON;
    const _Unwind_Reason_Code r = pers(1, _UA_SEARCH_PHASE, s->exc->exception_class, s->exc, ctx);
    if (r == _URC_CONTINUE_UNWIND) return _URC_NO_REASON;
    s->outcome = 2;  // a handler, or an error that libstdc++'s throw will meet the same way
    return _URC_NORMAL_STOP;
  }

  bool have_throw_hooks() { return have_hooks() && __eh_find_destination != nullptr && __eh_throw_detached != nullptr; }
}  // namespace

namespace
{
  // libstdc++'s __cxa_throw and __cxa_rethrow, from the functions they are made of (libsupc++/eh_throw.cc): the
  // exception goes to the unwinder, and a throw nothing catches terminates.
  __attribute__((noreturn, noinline)) void library_throw(void* obj, std::type_info* tinfo, void (*dest)(void*))
  {
    library_globals()->uncaught++;
    (void)abi::__cxa_init_primary_exception(obj, tinfo, dest);
    *refcount_of(obj) = 1;
    _Unwind_RaiseException(&header_of(obj)->unwind);
    abi::__cxa_begin_catch(&header_of(obj)->unwind);
    std::terminate();
  }

  __attribute__((noreturn, noinline)) void library_rethrow()
  {
    cxa_globals* g = library_globals();
    cxa_header* h = g->caught;
    g->uncaught++;
    if (h != nullptr) {
      if (h->unwind.exception_class == gxx_class || h->unwind.exception_class == gxx_dependent_class) {
        h->handler_count = -h->handler_count;  // rethrown: __cxa_end_catch keeps it
      } else {
        g->caught = nullptr;  // a foreign exception
      }
      _Unwind_Resume_or_Rethrow(&h->unwind);
      abi::__cxa_begin_catch(&h->unwind);
    }
    std::terminate();
  }

  // The primary object of the exception the innermost handler of gcc-compiled code is handling, or nullptr (none, or
  // not a C++ exception of libstdc++). Not std::current_exception of the library: it would take its reference through
  // exception_ptr::_M_addref, which is this file's.
  void* library_caught_object()
  {
    cxa_header* h = library_globals()->caught;
    if (h == nullptr) return nullptr;
    if (h->unwind.exception_class == gxx_class) return &h->unwind + 1;
    if (h->unwind.exception_class == gxx_dependent_class) return h->type_or_primary;
    return nullptr;
  }
}  // namespace

namespace __cxxabiv1
{
  extern "C" void __cxa_throw(void* obj, std::type_info* tinfo, void (*dest)(void*))
  {
    const std::type_info* t;
    int flags;
    if (have_throw_hooks() && describe_for_edg(tinfo, &t, &flags)) {
      void* entry = __eh_find_destination(t, flags, obj);
      if (entry != nullptr) {
        (void)__cxa_init_primary_exception(obj, tinfo, dest);
        // The unwinder's header is the last member of the __cxa_exception that precedes the object.
        handler_search s = {(uintptr_t)entry, &header_of(obj)->unwind, 0};
        _Unwind_Backtrace(search_frame, &s);
        if (s.outcome == 1) __eh_throw_detached(adopt_library_exception(obj));
      }
    }
    library_throw(obj, tinfo, dest);  // initializes the header again
  }

  // `throw;` in a handler of gcc-compiled code: the same decision for the exception being handled. When EDG's handler
  // gets it, the library's handler is ended here (__cxa_end_catch, which its frame would call on the way out) unless
  // the unwinder runs that frame's cleanups (NFCXX_EH_UNWIND=1 programs: lib/ehshim/nfcxx_eh_unwind.h).
  extern "C" void __cxa_rethrow()
  {
    const std::type_info* t;
    int flags;
    void* obj = have_throw_hooks() ? library_caught_object() : nullptr;
    if (obj != nullptr && describe_for_edg(__cxa_current_exception_type(), &t, &flags)) {
      void* entry = __eh_find_destination(t, flags, obj);
      if (entry != nullptr) {
        handler_search s = {(uintptr_t)entry, &header_of(obj)->unwind, 0};
        _Unwind_Backtrace(search_frame, &s);
        if (s.outcome == 1) {
          void* handle = adopt_library_exception(obj);  // its reference keeps the object past the end of the catch
          if (!(&__nfcxx_eh_unwind_frames != nullptr && __nfcxx_eh_unwind_frames)) __cxa_end_catch();
          __eh_throw_detached(handle);
        }
      }
    }
    library_rethrow();
  }
}  // namespace __cxxabiv1


// --- the vtables of the type_info classes ---------------------------------------------------------------------------
//
// EDG's runtime (libC.a, typeinfo.c) defines the type_info objects of the fundamental types, of pointers to them and of
// std::exception and the classes around it, and the executable exports them because libstdc++ and every C++ library
// refer to them: one object per type, which EDG's handlers need (they compare type_info names by address). Their
// vtables were EDG's too, with the destructors only: when gcc-compiled code caught, or dynamic_cast, through one of
// them (a library's own catch (int), a catch (std::exception&) of a class derived from it), libstdc++ called a virtual
// __do_catch or __do_upcast past the end and crashed. These definitions replace libC.a's (which are weak) with the
// tables libstdc++ itself has, slot for slot (offset, type_info, D1, D0, __is_pointer_p, __is_function_p, __do_catch,
// __do_upcast, then the class or pointer ones), naming libstdc++'s functions; the type_info layouts are the IA-64 ABI's
// in both. Freestanding programs link libC.a without this file and keep EDG's tables.
// (extern: a const object at namespace scope would have internal linkage.)
extern "C"
{
    void nfcxx_vf0() __asm__("_ZN10__cxxabiv116__enum_type_infoD1Ev");
    void nfcxx_vf1() __asm__("_ZN10__cxxabiv116__enum_type_infoD0Ev");
    void nfcxx_vf2() __asm__("_ZNKSt9type_info14__is_pointer_pEv");
    void nfcxx_vf3() __asm__("_ZNKSt9type_info15__is_function_pEv");
    void nfcxx_vf4() __asm__("_ZNKSt9type_info10__do_catchEPKS_PPvj");
    void nfcxx_vf5() __asm__("_ZNKSt9type_info11__do_upcastEPKN10__cxxabiv117__class_type_infoEPPv");
    void nfcxx_vf6() __asm__("_ZN10__cxxabiv117__array_type_infoD1Ev");
    void nfcxx_vf7() __asm__("_ZN10__cxxabiv117__array_type_infoD0Ev");
    void nfcxx_vf8() __asm__("_ZN10__cxxabiv120__function_type_infoD1Ev");
    void nfcxx_vf9() __asm__("_ZN10__cxxabiv120__function_type_infoD0Ev");
    void nfcxx_vf10() __asm__("_ZNK10__cxxabiv120__function_type_info15__is_function_pEv");
    void nfcxx_vf11() __asm__("_ZN10__cxxabiv123__fundamental_type_infoD1Ev");
    void nfcxx_vf12() __asm__("_ZN10__cxxabiv123__fundamental_type_infoD0Ev");
    void nfcxx_vf13() __asm__("_ZN10__cxxabiv117__class_type_infoD1Ev");
    void nfcxx_vf14() __asm__("_ZN10__cxxabiv117__class_type_infoD0Ev");
    void nfcxx_vf15() __asm__("_ZNK10__cxxabiv117__class_type_info10__do_catchEPKSt9type_infoPPvj");
    void nfcxx_vf16() __asm__("_ZNK10__cxxabiv117__class_type_info11__do_upcastEPKS0_PPv");
    void nfcxx_vf17() __asm__("_ZNK10__cxxabiv117__class_type_info11__do_upcastEPKS0_PKvRNS0_15__upcast_resultE");
    void nfcxx_vf18() __asm__("_ZNK10__cxxabiv117__class_type_info12__do_dyncastElNS0_10__sub_kindEPKS0_PKvS3_S5_RNS0_16__dyncast_resultE");
    void nfcxx_vf19() __asm__("_ZNK10__cxxabiv117__class_type_info20__do_find_public_srcElPKvPKS0_S2_");
    void nfcxx_vf20() __asm__("_ZN10__cxxabiv120__si_class_type_infoD1Ev");
    void nfcxx_vf21() __asm__("_ZN10__cxxabiv120__si_class_type_infoD0Ev");
    void nfcxx_vf22() __asm__("_ZNK10__cxxabiv120__si_class_type_info11__do_upcastEPKNS_17__class_type_infoEPKvRNS1_15__upcast_resultE");
    void nfcxx_vf23() __asm__("_ZNK10__cxxabiv120__si_class_type_info12__do_dyncastElNS_17__class_type_info10__sub_kindEPKS1_PKvS4_S6_RNS1_16__dyncast_resultE");
    void nfcxx_vf24() __asm__("_ZNK10__cxxabiv120__si_class_type_info20__do_find_public_srcElPKvPKNS_17__class_type_infoES2_");
    void nfcxx_vf25() __asm__("_ZN10__cxxabiv121__vmi_class_type_infoD1Ev");
    void nfcxx_vf26() __asm__("_ZN10__cxxabiv121__vmi_class_type_infoD0Ev");
    void nfcxx_vf27() __asm__("_ZNK10__cxxabiv121__vmi_class_type_info11__do_upcastEPKNS_17__class_type_infoEPKvRNS1_15__upcast_resultE");
    void nfcxx_vf28() __asm__("_ZNK10__cxxabiv121__vmi_class_type_info12__do_dyncastElNS_17__class_type_info10__sub_kindEPKS1_PKvS4_S6_RNS1_16__dyncast_resultE");
    void nfcxx_vf29() __asm__("_ZNK10__cxxabiv121__vmi_class_type_info20__do_find_public_srcElPKvPKNS_17__class_type_infoES2_");
    void nfcxx_vf30() __asm__("_ZN10__cxxabiv117__pbase_type_infoD1Ev");
    void nfcxx_vf31() __asm__("_ZN10__cxxabiv117__pbase_type_infoD0Ev");
    void nfcxx_vf32() __asm__("_ZNK10__cxxabiv117__pbase_type_info10__do_catchEPKSt9type_infoPPvj");
    void nfcxx_vf33() __asm__("_ZNK10__cxxabiv117__pbase_type_info15__pointer_catchEPKS0_PPvj");
    void nfcxx_vf34() __asm__("_ZN10__cxxabiv119__pointer_type_infoD1Ev");
    void nfcxx_vf35() __asm__("_ZN10__cxxabiv119__pointer_type_infoD0Ev");
    void nfcxx_vf36() __asm__("_ZNK10__cxxabiv119__pointer_type_info14__is_pointer_pEv");
    void nfcxx_vf37() __asm__("_ZNK10__cxxabiv119__pointer_type_info15__pointer_catchEPKNS_17__pbase_type_infoEPPvj");
    void nfcxx_vf38() __asm__("_ZN10__cxxabiv129__pointer_to_member_type_infoD1Ev");
    void nfcxx_vf39() __asm__("_ZN10__cxxabiv129__pointer_to_member_type_infoD0Ev");
    void nfcxx_vf40() __asm__("_ZNK10__cxxabiv129__pointer_to_member_type_info15__pointer_catchEPKNS_17__pbase_type_infoEPPvj");
    extern const char nfcxx_ti_16__enum_type_info __asm__("_ZTIN10__cxxabiv116__enum_type_infoE");
    extern const char nfcxx_ti_17__array_type_info __asm__("_ZTIN10__cxxabiv117__array_type_infoE");
    extern const char nfcxx_ti_20__function_type_info __asm__("_ZTIN10__cxxabiv120__function_type_infoE");
    extern const char nfcxx_ti_23__fundamental_type_info __asm__("_ZTIN10__cxxabiv123__fundamental_type_infoE");
    extern const char nfcxx_ti_17__class_type_info __asm__("_ZTIN10__cxxabiv117__class_type_infoE");
    extern const char nfcxx_ti_20__si_class_type_info __asm__("_ZTIN10__cxxabiv120__si_class_type_infoE");
    extern const char nfcxx_ti_21__vmi_class_type_info __asm__("_ZTIN10__cxxabiv121__vmi_class_type_infoE");
    extern const char nfcxx_ti_17__pbase_type_info __asm__("_ZTIN10__cxxabiv117__pbase_type_infoE");
    extern const char nfcxx_ti_19__pointer_type_info __asm__("_ZTIN10__cxxabiv119__pointer_type_infoE");
    extern const char nfcxx_ti_29__pointer_to_member_type_info __asm__("_ZTIN10__cxxabiv129__pointer_to_member_type_infoE");
    extern const void* const nfcxx_vt_16__enum_type_info[] __asm__("_ZTVN10__cxxabiv116__enum_type_infoE") = {
      nullptr,
      &nfcxx_ti_16__enum_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf0),
      reinterpret_cast<const void*>(&nfcxx_vf1),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf4),
      reinterpret_cast<const void*>(&nfcxx_vf5)};
    extern const void* const nfcxx_vt_17__array_type_info[] __asm__("_ZTVN10__cxxabiv117__array_type_infoE") = {
      nullptr,
      &nfcxx_ti_17__array_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf6),
      reinterpret_cast<const void*>(&nfcxx_vf7),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf4),
      reinterpret_cast<const void*>(&nfcxx_vf5)};
    extern const void* const nfcxx_vt_20__function_type_info[] __asm__("_ZTVN10__cxxabiv120__function_type_infoE") = {
      nullptr,
      &nfcxx_ti_20__function_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf8),
      reinterpret_cast<const void*>(&nfcxx_vf9),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf10),
      reinterpret_cast<const void*>(&nfcxx_vf4),
      reinterpret_cast<const void*>(&nfcxx_vf5)};
    extern const void* const nfcxx_vt_23__fundamental_type_info[] __asm__("_ZTVN10__cxxabiv123__fundamental_type_infoE") = {
      nullptr,
      &nfcxx_ti_23__fundamental_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf11),
      reinterpret_cast<const void*>(&nfcxx_vf12),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf4),
      reinterpret_cast<const void*>(&nfcxx_vf5)};
    extern const void* const nfcxx_vt_17__class_type_info[] __asm__("_ZTVN10__cxxabiv117__class_type_infoE") = {
      nullptr,
      &nfcxx_ti_17__class_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf13),
      reinterpret_cast<const void*>(&nfcxx_vf14),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf15),
      reinterpret_cast<const void*>(&nfcxx_vf16),
      reinterpret_cast<const void*>(&nfcxx_vf17),
      reinterpret_cast<const void*>(&nfcxx_vf18),
      reinterpret_cast<const void*>(&nfcxx_vf19)};
    extern const void* const nfcxx_vt_20__si_class_type_info[] __asm__("_ZTVN10__cxxabiv120__si_class_type_infoE") = {
      nullptr,
      &nfcxx_ti_20__si_class_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf20),
      reinterpret_cast<const void*>(&nfcxx_vf21),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf15),
      reinterpret_cast<const void*>(&nfcxx_vf16),
      reinterpret_cast<const void*>(&nfcxx_vf22),
      reinterpret_cast<const void*>(&nfcxx_vf23),
      reinterpret_cast<const void*>(&nfcxx_vf24)};
    extern const void* const nfcxx_vt_21__vmi_class_type_info[] __asm__("_ZTVN10__cxxabiv121__vmi_class_type_infoE") = {
      nullptr,
      &nfcxx_ti_21__vmi_class_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf25),
      reinterpret_cast<const void*>(&nfcxx_vf26),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf15),
      reinterpret_cast<const void*>(&nfcxx_vf16),
      reinterpret_cast<const void*>(&nfcxx_vf27),
      reinterpret_cast<const void*>(&nfcxx_vf28),
      reinterpret_cast<const void*>(&nfcxx_vf29)};
    extern const void* const nfcxx_vt_17__pbase_type_info[] __asm__("_ZTVN10__cxxabiv117__pbase_type_infoE") = {
      nullptr,
      &nfcxx_ti_17__pbase_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf30),
      reinterpret_cast<const void*>(&nfcxx_vf31),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf32),
      reinterpret_cast<const void*>(&nfcxx_vf5),
      reinterpret_cast<const void*>(&nfcxx_vf33)};
    extern const void* const nfcxx_vt_19__pointer_type_info[] __asm__("_ZTVN10__cxxabiv119__pointer_type_infoE") = {
      nullptr,
      &nfcxx_ti_19__pointer_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf34),
      reinterpret_cast<const void*>(&nfcxx_vf35),
      reinterpret_cast<const void*>(&nfcxx_vf36),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf32),
      reinterpret_cast<const void*>(&nfcxx_vf5),
      reinterpret_cast<const void*>(&nfcxx_vf37)};
    extern const void* const nfcxx_vt_29__pointer_to_member_type_info[] __asm__("_ZTVN10__cxxabiv129__pointer_to_member_type_infoE") = {
      nullptr,
      &nfcxx_ti_29__pointer_to_member_type_info,
      reinterpret_cast<const void*>(&nfcxx_vf38),
      reinterpret_cast<const void*>(&nfcxx_vf39),
      reinterpret_cast<const void*>(&nfcxx_vf2),
      reinterpret_cast<const void*>(&nfcxx_vf3),
      reinterpret_cast<const void*>(&nfcxx_vf32),
      reinterpret_cast<const void*>(&nfcxx_vf5),
      reinterpret_cast<const void*>(&nfcxx_vf40)};
}

#endif  // __GLIBCXX__

// --- libc++ (macOS) -----------------------------------------------------------------------------------------------
//
// libc++'s exception_ptr is one pointer that libc++abi reference-counts, and its copy, assignment, destructor,
// current_exception and rethrow_exception are exported from libc++.dylib. An exception made by EDG has an EDG handle
// instead (the entry address of the EDG runtime), so those members are defined here, in the program, and the
// program's calls bind to them (the dylib keeps its own internal calls). The handle is pinned and released with the EDG
// hooks. This file is compiled by nfcxx, so the definitions use the EDG calling convention, and the thunk list of
// scripts/sret-darwin-symbols.txt does not name them.
#ifdef _LIBCPP_VERSION

extern "C"
{
  void* __eh_pin_current(void) __attribute__((weak));
  void* __eh_make_detached(const std::type_info*, void (*)(void*), int, int*, void*, void (*)(void*))
      __attribute__((weak));
  void __eh_pin(void*) __attribute__((weak));
  void __eh_unpin(void*) __attribute__((weak));
  void __eh_rethrow_pinned(void*) __attribute__((weak));
}

// make_exception_ptr (libc++'s header) allocates the object with __cxa_allocate_exception, initializes it with
// __cxa_init_primary_exception and wraps it with __from_native_exception_pointer. Those are libc++abi's, and the header
// marks the first two overridable, so they are defined here: the object gets a prefix that keeps its type and cleanup,
// and the wrap makes an EDG detached entry (the same rules as the libstdc++ path above: a pointer is described by its
// pointee and its qualifiers).
namespace
{
  struct nfcxx_cxa_prefix {
    const std::type_info* type;
    void (*cleanup)(void*);
    long reserved[2];
  };
  const size_t nfcxx_prefix_size = sizeof(nfcxx_cxa_prefix);

  nfcxx_cxa_prefix* nfcxx_prefix_of(void* obj) { return reinterpret_cast<nfcxx_cxa_prefix*>(static_cast<char*>(obj) - nfcxx_prefix_size); }

  // The EDG entry's destructor and free function: destroy the object, then release its block.
  void nfcxx_destroy_and_free(void* obj)
  {
    nfcxx_cxa_prefix* p = nfcxx_prefix_of(obj);
    void (*cleanup)(void*) = p->cleanup;
    void* base = static_cast<char*>(obj) - nfcxx_prefix_size;
    if (cleanup != nullptr) cleanup(obj);
    std::free(base);
  }
}  // namespace

extern "C"
{
  void* __cxa_allocate_exception(size_t size) throw()
  {
    void* base = std::malloc(nfcxx_prefix_size + size);
    if (base == nullptr) std::terminate();
    return static_cast<char*>(base) + nfcxx_prefix_size;
  }

  void __cxa_free_exception(void* obj) throw()
  {
    std::free(static_cast<char*>(obj) - nfcxx_prefix_size);
  }

  ::__cxxabiv1::__cxa_exception* __cxa_init_primary_exception(void* obj, std::type_info* type, void (*cleanup)(void*)) throw()
  {
    nfcxx_cxa_prefix* p = nfcxx_prefix_of(obj);
    p->type = type;
    p->cleanup = cleanup;
    return nullptr;
  }
}

namespace std
{
  exception_ptr exception_ptr::__from_native_exception_pointer(void* obj) noexcept
  {
    exception_ptr r;
    if (obj == nullptr || __eh_make_detached == nullptr) return r;
    const type_info* t = nfcxx_prefix_of(obj)->type;
    if (t == nullptr) return r;
    int flags = 0;
    if (t->name()[0] == 'P') {
      // Itanium __pbase_type_info (not declared by libc++abi's header): the flags and the pointee follow std::type_info.
      struct pbase { unsigned int flags; const std::type_info* pointee; };
      const pbase* pb = reinterpret_cast<const pbase*>(reinterpret_cast<const char*>(t) + sizeof(std::type_info));
      const char c = pb->pointee->name()[0];
      if (c == 'P' || c == 'M') return r;
      flags = 0x01;  // ETS_IS_POINTER
      if (pb->flags & 0x1) flags |= 0x02;  // __const_mask
      if (pb->flags & 0x2) flags |= 0x04;  // __volatile_mask
      r.__ptr_ = __eh_make_detached(pb->pointee, nullptr, flags, nullptr, obj, nfcxx_destroy_and_free);
    } else if (t->name()[0] == 'M') {
      return r;
    } else {
      r.__ptr_ = __eh_make_detached(t, nfcxx_destroy_and_free, flags, nullptr, obj, nullptr);
    }
    return r;
  }

  exception_ptr::exception_ptr(const exception_ptr& other) noexcept : __ptr_(other.__ptr_)
  {
    if (__ptr_ != nullptr && __eh_pin != nullptr) __eh_pin(__ptr_);
  }

  exception_ptr& exception_ptr::operator=(const exception_ptr& other) noexcept
  {
    if (other.__ptr_ != nullptr && __eh_pin != nullptr) __eh_pin(other.__ptr_);
    void* old = __ptr_;
    __ptr_ = other.__ptr_;
    if (old != nullptr && __eh_unpin != nullptr) __eh_unpin(old);
    return *this;
  }

  exception_ptr::~exception_ptr() noexcept
  {
    if (__ptr_ != nullptr && __eh_unpin != nullptr) __eh_unpin(__ptr_);
  }

  exception_ptr current_exception() noexcept
  {
    exception_ptr r;
    if (__eh_pin_current != nullptr) r.__ptr_ = __eh_pin_current();
    return r;
  }

  // nested_exception (exported from libc++.dylib): its members copy and destroy the exception_ptr and rethrow it, so they
  // are defined here too; a call inside the dylib would otherwise reach libc++abi's functions with an EDG handle.
  nested_exception::nested_exception() noexcept : __ptr_(current_exception()) {}
  nested_exception::~nested_exception() noexcept {}
  void nested_exception::rethrow_nested() const
  {
    if (!__ptr_) terminate();
    rethrow_exception(__ptr_);
  }

  void rethrow_exception(exception_ptr p)
  {
    if (p.__ptr_ == nullptr || __eh_rethrow_pinned == nullptr) terminate();
    __eh_rethrow_pinned(p.__ptr_);
    terminate();
  }
}  // namespace std

#endif  // _LIBCPP_VERSION
