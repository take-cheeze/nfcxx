# Clean-room macOS arm64 headers (compile checks only)

These headers let nfcxx's macOS arm64 C path compile on a Linux host, with `NFCXX_MACOS_SYSROOT=<this directory>`
(see `scripts/qbe-cc`). They are for **compile and assembly checks only**. They are not a libSystem, not a link
target, and nothing built with them has been run or linked as a Mach-O binary.

## Sources

Written by hand for this directory from public sources only:
- the C11 standard (7.4 ctype, 7.5 errno, 7.13 setjmp, 7.20 stdint, 7.21 stdio, 7.22 stdlib, 7.24 string) and
  the LP64 limits of C11 5.2.4.2;
- POSIX (alloca.h, the restrict-qualified string and stdio signatures);
- the public convention of Darwin's open-source libc for two names: `__error()` (errno) and `__stdinp`,
  `__stdoutp`, `__stderrp` (the standard streams).

No file of the Apple SDK was opened, copied or consulted. The `jmp_buf` size (48 ints) is a placeholder, not
checked against Darwin.

Compiler-owned headers (`stddef.h`, `stdarg.h`, `float.h`, the `stdint.h` and `limits.h` wrappers, and so on) come
from clang's resource directory (`clang -print-resource-dir`/include), which is part of LLVM.

## Covered

`stdio.h`, `stdlib.h`, `string.h`, `ctype.h`, `errno.h`, `limits.h`, `stdint.h`, `setjmp.h`, `alloca.h`. These are the
headers the C files in `tests/c` include.

## Not covered (so these fail or are missing)

- Any other system header: `unistd.h`, `pthread.h`, `dlfcn.h`, `sys/*`, `mach/*` (including the ARM register state
  used by `sys/signal.h`), `locale.h`, `wchar.h`, `math.h`, `time.h`, `signal.h`. A file that includes one fails to
  compile.
- The C++ standard library. libc++ headers and `__config_site` are not provided, so no `.cpp` test compiles against
  this directory.
- Exported symbols: there is no `.tbd` export list here, so there is nothing to link against.
- ABI details that were not written from a public specification of Darwin: the `jmp_buf` size, the layout of
  `FILE`, and any `__attribute__` that the SDK relies on.

## Using it

    NFCXX_MACOS_SYSROOT=/path/to/this/include scripts/qbe-cc -S file.c -o file.s

The compile uses `clang --target=arm64-apple-darwin`, and the assembly of `-c` is Mach-O from clang's integrated
assembler. Linking is not attempted in this mode.
