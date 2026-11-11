# Clean-room macOS arm64 headers (compile checks only)

These headers let nfcxx's macOS arm64 path compile on a Linux host, with `NFCXX_MACOS_SYSROOT` set to
`tests/macos-sysroot/include` (see `scripts/qbe-cc`). They are for **compile and assembly checks only**. They are not
a libSystem, not a link target, and nothing built with them has been run or linked as a Mach-O binary.

## Sources

Written by hand for this directory from public sources only:
- the C11 standard (7.4 ctype, 7.5 errno, 7.8 inttypes, 7.12 math, 7.13 setjmp, 7.20 stdint, 7.21 stdio, 7.22 stdlib,
  7.23 string, 7.27 time, 7.29 wchar) and the LP64 limits of C11 5.2.4.2;
- POSIX (alloca.h, pthread.h and sched.h with the functions libc++'s threading layer calls, nanosleep in time.h, and
  the restrict-qualified string and stdio signatures);
- the public convention of Darwin's open-source libc for two names: `__error()` (errno) and `__stdinp`, `__stdoutp`,
  `__stderrp` (the standard streams).

No file of the Apple SDK or Xcode was opened, copied or consulted. The `jmp_buf` size (48 ints) is a placeholder, not
checked against Darwin.

`include/stdio.h`, `stdlib.h`, `string.h`, `time.h` and `wchar.h` map `restrict` to `__restrict` under `__cplusplus`,
since C++ has no `restrict` keyword.

Compiler-owned headers (`stddef.h`, `stdarg.h`, `float.h`, and so on) come from clang's resource directory, which is
part of LLVM.

## C++ (`cxx/`)

`cxx/__config_site` is LLVM 18's file for libc++, with localization turned off (`_LIBCPP_HAS_NO_LOCALIZATION`), since
the Darwin `xlocale.h` is not written here. The libc++ headers themselves are LLVM's open-source ones (Apache-2.0 with
LLVM exception), from the `libc++-18-dev` package, not from Apple. Put `cxx/` ahead of the libc++ directory.

Known differences from Apple's libc++, so a compile here proves nothing about ABI:
- no Apple ABI tags (for example `B9nqe210106`) in the open headers, so mangled names will not match Apple's dylib;
- availability macros and localization differ;
- threads use the pthread API. `pthread.h` and `sched.h` here declare the functions libc++ calls, with opaque object
  types (`pthread_t` is a pointer, as on Darwin), so layouts and `*_INITIALIZER` values are not Darwin's.

## Covered and not covered

Covered: `stdio.h`, `stdlib.h`, `string.h`, `ctype.h`, `errno.h`, `limits.h`, `stdint.h`, `setjmp.h`, `alloca.h`, `math.h`,
`time.h`, `wchar.h`, `pthread.h`, `sched.h`. These cover the C files in `tests/c` and the C++ sources in `tests/cases` that are not gated for macOS.

Not covered (a file that includes one of these fails to compile): `unistd.h`, `dlfcn.h`, `sys/*`, `mach/*`
(including the ARM register state used by `sys/signal.h`), `locale.h`, `signal.h`. The exported symbols are not listed
here, so there is nothing to link against.

## Compiling C++ (`scripts/macos-cxx-check.sh`)

    scripts/macos-cxx-check.sh SRC.cpp OUT.s

clang preprocesses SRC for `arm64-apple-darwin` against these headers and `cxx/` (blocks off), nfcxx's front end reads that
text in clang's dialect with only these directories as system includes, and `scripts/qbe-cc` compiles the generated C for
Darwin. It stops at assembly. The EDG front end still defines Linux macros and lays out types for its build host (for
example `long double`), so a pass means the source reached Darwin assembly, not ABI parity. Over `tests/cases`, 20 of 24
sources reach assembly; the 4 others are `eval_order_calls` (localization is off), `qbe_atomics` (EDG rejects `_Atomic`
in C++), `qbe_gnu_forms` (GNU forms EDG rejects) and `qbe_int3_break` (x86 inline asm).

## Using it

    NFCXX_MACOS_SYSROOT=$PWD/tests/macos-sysroot/include scripts/qbe-cc -S file.c -o file.s

The compile uses `clang --target=arm64-apple-darwin`, and `-c` produces Mach-O from clang's integrated assembler.
Linking is not attempted in this mode.
