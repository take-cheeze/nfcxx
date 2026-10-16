# Cross-compiling macOS arm64 on Linux (compile checks)

This configuration lets a Linux host compile C and C++ for macOS arm64 through nfcxx's Darwin paths and stop at
assembly. Nothing is linked and nothing is run. It is for checking the code generator, not for producing macOS
binaries.

## Requirements

Linux only (`uname -s` must say Linux). On Ubuntu 24.04 arm64 these packages cover it:

- `clang` (18), `cmake`, `ninja-build`, `gcc` (EDG and QBE are built for the host);
- `llvm-18` (`llvm-mc`), `lld-18` (`ld64.lld`), `libc++-18-dev` (the open libc++ headers).

`scripts/setup-cross-macos.sh` reports any missing one with the package to install.

## Commands

    scripts/setup-cross-macos.sh     # builds EDG, QBE and cproc if missing; writes build/cross-macos.env
    scripts/cross-macos-check.sh     # prints the C and C++ counts, and each failure's first error line

The second `setup-cross-macos.sh` run builds nothing (it reports "already built") and rewrites the same env file.
`cross-macos-check.sh` sources `build/cross-macos.env`, which sets:

- `NFCXX_MACOS_CLEANROOM`: the sysroot root (`tests/macos-sysroot`, with `cxx/` and `include/`);
- `NFCXX_MACOS_SYSROOT`: its `include/` directory, which `scripts/qbe-cc` reads;
- `NFCXX_LIBCXX`: the open libc++ headers;
- `PATH`, with the LLVM 18 tools first.

The default Linux build does not read this file, so nothing changes unless the file is sourced.

## What it covers

- **C** (`tests/c/*.c`): `scripts/qbe-cc -S` with `NFCXX_C_INPUT=1` and `NFCXX_MACOS_SYSROOT`. clang preprocesses the
  file for `arm64-apple-darwin` against the clean-room headers, then QBE emits arm64 assembly.
- **C++** (`tests/cases/*.cpp`): `scripts/macos-cxx-check.sh`. clang preprocesses for the Darwin target, nfcxx's
  front end (`--emit-c`) reads that text, and `qbe-cc` emits assembly. See the next section for why clang runs first.

## What it does not cover

- **Linking and running.** No Mach-O binary is produced by these checks, and none is run.
- **ABI.** The clean-room headers (`tests/macos-sysroot`) are written from the C11 standard, POSIX and LLVM's open
  libc++. They are not Apple's, and they make no ABI claim: `jmp_buf`'s size is a placeholder, the libc++ config turns
  localization off, and Apple's ABI tags (for example `B9nqe210106`) are absent. A pass means the source reached
  assembly, not that the layout matches Darwin's.
- **The front end on Darwin types.** EDG defines `__linux__` internally and lays out types for its Linux build host
  (for example 128-bit `long double`). No flag removes that, so the C++ check runs clang's preprocessor for the Darwin
  target first. The 20 passing C++ sources therefore do not show that nfcxx's own preprocessing handles Darwin headers.
- **sret thunks.** `qbe-cc` skips the class-return thunks on the macOS path, since they need Apple's export list.
- **Blocks.** Apple's `^` syntax is off (`-fno-blocks`), as it is for EDG.

## Known failures

The check does not read the `run.sh` markers, so it counts every file in the directory. Several failures below are
files `run.sh` skips on arm64; they are listed with their reasons so the count can be read against the markers.

C, 4 of 23 (`tests/c`):

- `float16_abi_peer.c`: inline assembly, which QBE does not support on arm64 (`inline assembly is not yet supported`).
- `va_struct_take.c`: `va_arg` of a non-scalar aggregate, which the front end accepts only for x86-64 integer-class
  structures.
- `float128_abi.c` and `ldouble_ops.c`: QBE asserts in `spill.c` (`v->t[0] == T.rglob`) on the arm64 Darwin path. Both
  are `X86-ONLY` in `run.sh`, so they are skipped on any non-x86-64 host; the cross check does not read those markers
  and counts them. The cause is not found.

C++, 4 of 24 (`tests/cases`):

- `eval_order_calls.cpp`: includes `<iostream>`, which needs localization; the config turns it off.
- `qbe_atomics.cpp`: `_Atomic` is rejected by cproc (`_Atomic type qualifier is not yet supported`), which reads the
  preprocessed C that nfcxx's front end emits.
- `qbe_gnu_forms.cpp`: a GNU form the front end's C++ parser rejects (`name followed`, line 26). `run.sh` treats this
  file as `MACOS-XFAIL-qbe` (the QBE path emits a directive ld64 and cproc do not accept), not as a skip.
- `qbe_int3_break.cpp`: x86-64 inline assembly, which the front end's C++ parser rejects on this target (`namespace`,
  line 18); gated `X86-ONLY`.

## Why `NFCXX_C_INPUT=1` for the C check

`qbe-cc` passes `-undef` to clang for preprocessing. That strips the target's predefined macros, including
`__SIZE_TYPE__`, so any file that includes `stddef.h` fails with `declaration has no type specifier`. The hand-written
C branch of `qbe-cc` re-defines the target's macros from `clang -dM -E` (minus the GCC-identity ones), and that
restores them. With the setting, the C count is 19 of 23 instead of 11 of 23. The C++ path feeds EDG's already
preprocessed output and keeps the default branch.
