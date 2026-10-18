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

## Not provided here (report, do not stub)

`__cxa_uncaught_exception` (`libcxxabi/src/cxa_exception.cpp`, which needs the unwinder and the exception storage
code: part of the EH work), `__tlv_bootstrap` (Darwin's thread-local loader, not open source), and the
prelinker's libc++ template instances (`std::__sort`).
