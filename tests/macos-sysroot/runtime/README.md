# Open-source runtime for the macOS arm64 cross link

The cross link (scripts/cross-macos-link.sh) needs a few compiler-runtime and libc++abi names that Apple's system
library provides on a Mac and that the clean-room sysroot does not. They come from the open LLVM sources below, not from
stubs, so the cross link resolves them to real code. `build.sh` compiles them for `arm64-apple-darwin` and archives them
into `build/macos-rt/libnfcxx-darwin-rt.a`; the cross link adds that archive when it exists. Native builds never see it.

## Sources (LLVM 18.1.8, tag `llvmorg-18.1.8`, fetched verbatim from github.com/llvm/llvm-project)

| file | provides |
| --- | --- |
| `compiler-rt/lib/builtins/atomic.c`, `assembly.h` | `___atomic_load_{1,2,4,8,16}`, `_store_`, `_exchange_`, `_compare_exchange_`, `_fetch_{add,sub,and,or,xor}_` (sized) |
| `libcxxabi/src/stdlib_new_delete.cpp` | aligned `operator new` / `operator delete` (`__Znwm`/`__Zdlm` with `std::align_val_t`, and the array and nothrow forms) |
| `libcxxabi/src/cxa_virtual.cpp` | `___cxa_pure_virtual` |
| `libcxxabi/src/cxa_vector.cpp` | `___cxa_vec_ctor`, `___cxa_vec_dtor` |
| `libcxxabi/src/abort_message.cpp`, `abort_message.h` | `_abort_message` (used by the operator new paths) |
| `libcxxabi/include/cxxabi.h`, `__cxxabi_config.h` | headers for the above |
| `libcxx/src/include/overridable_function.h` | header used by `stdlib_new_delete.cpp` |
| `libcxx/src/new_handler.cpp`, `libcxx/src/include/atomic_support.h` | `std::get_new_handler` |
| `libcxxabi/src/stdlib_typeinfo.cpp` | `std::type_info::~type_info` |
| `libcxxabi/src/private_typeinfo.cpp`, `private_typeinfo.h` | the `__cxxabiv1::__vmi_class_type_info` vtable and the type-info classes |

Licence: Apache License 2.0 with LLVM exceptions (see the LLVM project LICENSE.TXT).

## Choices

- `atomic.c` is compiled with `-U__APPLE__`. The file takes its lock from `libkern/OSAtomic.h` on Apple, which is an SDK
  header this sysroot does not have. The fallback branch is C11 atomics, and it defines the same sized functions.
- The libc++abi sources are compiled against the open libc++ headers (`NFCXX_LIBCXX`) with the clean-room `__config_site`,
  not Apple's libc++ headers. Their ABI tags and availability macros may differ from Apple's, so a successful link here
  does not prove binary compatibility with Apple's libc++ dylib; the Mac run is the check.

## Stubs (no behaviour)

- `__tlv_bootstrap` (Darwin's thread-local loader, not open source): exported by `tests/macos-sysroot/lib/libSystem.tbd` so the link resolves. It has no behaviour. Any `thread_local` access at run time will fail, so a program that uses one must not be run on the Mac until this is implemented.

## Built here, but the symbols are provided by the EH work

- `std::type_info` typeinfo (`__ZTISt9type_info`): built from `stdlib_typeinfo.cpp` with RTTI on. The key function emits the object only with RTTI, so the build script compiles that one file with `-frtti`.

## Not provided here (report, do not stub)

`__cxa_uncaught_exception` (`libcxxabi/src/cxa_exception.cpp`, open source, but building it needs libunwind's configuration
and headers and a port of libc++abi's exception storage to this libc++ 18 header set; it failed on the missing
`__libunwind_config.h` and on `std::unexpected_handler`, which libc++ 18 no longer declares). That is part of the EH work, so it is
not built here. The prelinker's libc++ template instances (`std::__sort`) wait on the demangler pin.

## libunwind and the libc++abi exception runtime (added)

- **libunwind**, LLVM 18.1.8 (`libunwind/src`, `libunwind/include`, Apache-2.0 with LLVM exception), built native-only for the
  arm64 target. Its availability macro is made empty on the command line (`__OSX_AVAILABLE_STARTING(a,b)=`), so the SDK's
  `AvailabilityMacros.h` is not used. Its Darwin headers are LLVM's `compact_unwind_encoding.h`, a minimal `mach-o/dyld.h`
  written from the public `_dyld_register_func_for_remove_image` signature, and the `dladdr` declaration in the clean-room
  `dlfcn.h`.
- **libc++abi exception runtime**, LLVM 18.1.8 (`libcxxabi/src`, `libcxxabi/include`): `cxa_exception`,
  `cxa_exception_storage`, `cxa_handlers` and `fallback_malloc` are built as C++17, and `cxa_default_handlers` as C++20
  (it uses `constinit`). `-D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS` keeps `std::unexpected_handler`, which
  libc++ 18 otherwise removes.
- **Duplicate symbols renamed, not dropped:** libc++abi's `std::set_new_handler` (cxa_default_handlers) and
  `std::get_new_handler` (cxa_handlers) are compiled under other names; libc++'s `new_handler.o` keeps the pair.
- **Symbol conflicts with Apple's system library:** the archive defines the libunwind names `_Unwind_*` (for example
  `_Unwind_RaiseException`, `_Unwind_Resume`, `_Unwind_Backtrace`) and `_unw_*`/`___unw_*`. Apple's `libSystem` exports the
  same public unwinder entry points. An executable linked with this archive uses the archive's copies for its own
  references; the system library's copies still serve any code that calls them. Two unwinders in one process is the same
  split recorded for libc++ throws (see docs/notes/cross-macos.md).
- **Stubs added (public names only):** `_dladdr`, `__dyld_find_unwind_sections`, `__dyld_register_func_for_remove_image`,
  `_calloc`, and the pthread key, mutex, once and rwlock functions libunwind uses.
