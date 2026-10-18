# Open-source runtime for the macOS arm64 cross link

The cross link (scripts/cross-macos-link.sh) needs a few compiler-runtime and libc++abi names that Apple's system
library provides on a Mac and that the clean-room sysroot does not. They come from the open LLVM sources below, not from
stubs, so the cross link resolves them to real code. `build.sh` compiles them for `arm64-apple-darwin` and archives them
into `build/macos-rt/libnfcxx-darwin-rt.a`; the cross link adds that archive when it exists. Native builds never see it.

## Sources (LLVM 18.1.8, fetched at the commit in `LLVM_PIN`)

Pinned: tag `llvmorg-18.1.8`, commit `3b5b5c1ec4a3095ab096dd780e84d7ab81f3d7ff` (`LLVM_PIN`). Nothing from LLVM is
vendored in this repository: `build.sh` fetches exactly that commit from github.com/llvm/llvm-project at build time,
as a sparse, shallow clone of the three trees it needs, and stops if the checked-out commit is not the pin.

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
