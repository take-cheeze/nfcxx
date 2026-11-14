# Intel Knights Corner (k1om): `--target=linux_k1om`

nfcxx compiles freestanding C++ for the Intel Xeon Phi coprocessor 3120 series (Knights Corner, k1om) with the
k1om GCC 5.1.1 of Intel's MPSS 3.8.6, rebuilt for a modern host (Ubuntu 24.04, GCC 13).

```
scripts/setup-k1om.sh                                  # EDG tree for the host, and build/k1om/libC.a
./nfcxx --freestanding --target=linux_k1om prog.cpp -o prog
tests/k1om/run.sh                                      # ELF machine of each tests/k1om/*.cpp (EM_K1OM)
```

The toolchain is read from `NFCXX_K1OM_ROOT` (default `/opt/k1om`): `bin/k1om-mpss-linux-{gcc,as,ld,ar,ranlib,nm}`,
`sysroot/` with glibc 2.14.1 for k1om.

## What the target does

- **Front end**: EDG runs on the host, so the program is laid out for LP64 x86-64. k1om is LP64 too, so sizes and
  alignments agree. The predefined macros are the host's (`__x86_64__`, GCC 13's `_Float16`, `__bf16`), which is why
  the target is freestanding: hosted C++ headers come from GCC 13 and use types GCC 5 lacks.
- **Back end**: the gcc backend (`scripts/gcc-cc`) with `NFCXX_GCC=scripts/k1om-cc.rb`, which is the k1om GCC. It maps
  `-std=gnu17` to `gnu1x` and drops `-fdiagnostics-plain-output` and `-fkeep-static-functions` (newer GCC only).
- **Assembler**: `gcc-cc` runs `$NFCXX_AS` (default `as`). The target sets it to `scripts/k1om-bin/as`, which passes
  `--march=k1om`: without it, the assembler emits x86-64 objects that the k1om linker rejects.
- **Runtime**: `build/k1om/libC.a`, EDG's C++ runtime compiled for k1om by `setup-k1om.sh` through the same chain.
  `c99_complex.o` is left out (it needs `_Float16` and `__bf16`).

## Verified

- Freestanding C++ runs on the card: structs, templates, virtual calls with a virtual destructor (needs the k1om
  `libC.a`), double arithmetic. `tests/k1om/float_virtual.cpp` prints `fp=2812`.
- Not verified: hosted C++ (`<iostream>` and the like), exceptions thrown and caught on the card, `long double`.

## Not done

- No `linux_k1om` table in EDG's `lib_*` set, so the layout is the host's rather than an EDG-described target.
- No QBE back end for k1om. Knights Corner has no SSE or x87, and QBE's x86 back end emits SSE for floating point.
- The hosted C++ library (libstdc++ 5.1) is missing C++14/17 headers, so C++ beyond freestanding `lib/` is not
  available with this toolchain.
