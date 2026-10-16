# Cross-compiling macOS arm64 on Linux (compile checks)

This configuration lets a Linux host compile C and C++ for macOS arm64 through nfcxx's Darwin paths, stop at assembly,
and (for C) link Mach-O arm64 executables against a clean-room stub. Nothing is run. It checks the code generator and
the link line; it does not produce binaries that have been run on macOS.

## Requirements

Linux only (`uname -s` must say Linux). On Ubuntu 24.04 arm64 these packages cover it:

- `clang` (18), `cmake`, `ninja-build`, `gcc` (EDG and QBE are built for the host);
- `llvm-18` (`llvm-mc`), `lld-18` (`ld64.lld`), `libc++-18-dev` (the open libc++ headers).

`scripts/setup-cross-macos.sh` reports any missing one with the package to install.

## Commands

    scripts/setup-cross-macos.sh     # builds EDG, QBE and cproc if missing; writes build/cross-macos.env
    scripts/cross-macos-check.sh     # prints the C and C++ counts, and each failure's first error line
    scripts/cross-macos-check.sh --link   # the same, then links the C files that compile (see "Linking")

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

## Linking (C, `--link`)

For each C file that passes the C check, the script assembles the QBE output with `llvm-mc -triple=arm64-apple-darwin`
and links it with `ld64.lld -arch arm64 -platform_version macos 11.0 11.0`, against:

- the object `be/nfcxx_ldrt.c` compiled for arm64 Darwin with the clean-room headers (nfcxx's own runtime: `__int128`
  and float16 helpers and their compiler-rt names), and
- the link stub `tests/macos-sysroot/lib/libSystem.tbd`, passed as `-L ... -lSystem`.

The stub is a text-based (TBD v4) file with the export names listed below. It is written from public names (the C
standard, POSIX, and the Darwin names for `errno` and `stderr`, `___error` and `___stderrp`). It has no code and no
behaviour: it lets the linker resolve a name, nothing more.

Each executable is then checked: `llvm-objdump --macho --private-headers` must show `EXECUTE` and `ARM64`, and
`llvm-nm -u` must list only names the stub exports. Nothing is run. Result on this host: 12 of the 19 C files that
compile link to such executables (`alloca`, `arith`, `array_qual`, `builtins_overflow`, `builtins_overflow_mixed`,
`fabsf_builtin`, `float_limits`, `funcptr`, `stdio`, `struct_trailing_aligned`, `structs`, `volatile_setjmp`).

Stubbed names (each is imported by at least one linked program):
`_abort _fabsf _fprintf _ldexp _longjmp _memcpy _memset _printf _puts _qsort _setjmp _strcmp _strtol _toupper
_vsnprintf ___error ___stderrp dyld_stub_binder` and the compiler-rt names `___divti3 ___fixdfti ___fixsfti
___fixunsdfti ___fixunssfti ___floattidf ___floattisf ___floatuntidf ___floatuntisf ___modti3 ___udivti3 ___umodti3`.

The 7 C files that compile but do not link:

- `float128_ops.c`, `float16_gen.c`, `float16_ops.c`, `float16_wide.c`: they need `___nfcxx_f128_*` or `___nfcxx_f16_*`
  helpers that `be/nfcxx_ldrt.c` does not provide on arm64 (its float128 and `long double` parts are x87 code, x86-64
  only). Not a stub gap: the helpers do not exist for this target yet.
- `float16_abi_gcc.c`: needs `_g_dirty_to_qbe` and the other `_g_*` names from `float16_abi_peer.c`, which does not
  compile for arm64 (inline assembly). Its peer is missing.
- `va_struct.c`: needs `_take` from `va_struct_take.c`, which does not compile for arm64 (see Known failures).
- `mixed_c.c`: has no `main`; it is a unit linked with a C++ driver.

## What it does not cover

- **Running.** No executable is run. Linux cannot run Mach-O, and the run step needs a Mac with the real system.
- **Linking against Apple's libSystem.** The stub is not Apple's, so a link here shows that the names resolve and the
  Mach-O shape is right. It does not show that the symbols behave like Apple's, or that the program's ABI matches.
- **The C++ check does not link.** `--link` covers the C files only; the C++ sources would also need the open libc++
  and libc++abi names, which the stub does not yet export.
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
