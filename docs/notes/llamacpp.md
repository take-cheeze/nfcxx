# llama.cpp on the host side: ggml through nfcxx

`tests/llamacpp/run.sh` compiles llama.cpp's host-side ggml (ggml/src/*.c, *.cpp, and ggml-cpu/ with its tiled
sources) through the nfcxx driver on the gcc backend, and links `tests/llamacpp/ggml_cpu_check.c` (a small
`ggml_mul_mat` + `ggml_add` graph on the CPU backend, checked against a hand-computed result) against them. The clone
is `build/targets/llama.cpp` (`git clone --depth 1 https://github.com/ggml-org/llama.cpp.git`); the test skips without it.

## Result

- All 11 core files (`ggml.c`, `ggml-alloc.c`, `ggml-quants.c`, `ggml.cpp`, `ggml-backend*.cpp`, `gguf.cpp`,
  `ggml-opt.cpp`, `ggml-threading.cpp`) compile with the driver's C and C++ paths.
- The CPU backend (`ggml-cpu/*.c`, `*.cpp`, `tiled/*.cpp`) compiles with `-DGGML_CPU_GENERIC` and without the SSE
  predefines (see below): 23 objects in all.
- The link stops at one blocker (see the list): `XFAIL link` in `run.sh`. The check program does not run yet.

## Flags

llama.cpp's CMake gives `_GNU_SOURCE` on Linux (`ggml-cpu.c` needs it for `CPU_ZERO`). The test passes it, plus
`-DGGML_CPU_GENERIC` for `ggml-cpu/` (the portable code in `arch-fallback.h`). For the C++ files it also removes
`__SSE__`, `__SSE2__`, `__SSE3__` and `__SSSE3__`: gcc defines them on every x86-64 host, and `ggml-cpu-impl.h` then
includes `immintrin.h`, which needs AVX10.2 builtins EDG does not know (below). The x86 SIMD paths are not exercised.

## Driver changes this needed

- `--emit-c` takes the first source from `srcs`, not `files[0]` (which can be an `-I` option).
- `-m*` (ISA and target options) are no longer passed to EDG as files (eccp rejects `-mavx2`). They go to the C
  compile (`--c_to_obj_option`), and the macros gcc predefines for them (`gcc -mavx2 -dM`, the difference from plain
  gcc) go to the front end as `-D` options.
- `-c` with only C sources stops at the object (it used to link). `-o` names the object; otherwise `<source>.o`.
- The gcc backend's C compiler is `scripts/gcc-cc`, which removes `#pragma GCC unroll` lines from EDG's generated C.
  libstdc++ 15's `__find_if` has the pragma, and EDG passes it through in front of a declaration, which gcc rejects
  ("for, while or do statement expected before 'auto'").

## Blockers (next list)

1. **EDG does not know GCC 15's AVX10.2 builtins.** Any C++ file that includes `<immintrin.h>` fails:
   `error: identifier "__builtin_ia32_vcvt2ps2phx256_mask" is undefined` (also `__builtin_ia32_vcvt2ph2bf8512_mask`).
   GCC 15's `immintrin.h` includes `avx10_2*intrin.h` unconditionally, and the `-512` variants share `immintrin.h`'s own
   include guard, so the driver cannot skip them. The fix is in EDG's builtin table, not the driver. Until then the
   x86 SIMD code of ggml-cpu (and any program using `immintrin.h`) does not compile.
2. **Template instance across translation units.** `ggml-backend-reg.cpp.o` references
   `_ZNSt12__shared_ptrINSt10filesystem7__cxx114_DirELN9__gnu_cxx12_Lock_policyE2EED1Ev`
   (`std::__shared_ptr<std::filesystem::__cxx11::_Dir>::~__shared_ptr`), which no object defines. g++ defines it in
   each TU that uses it (weak); EDG's prelinker does not emit it for this TU. The link stops with
   `undefined reference to ...`.
3. **`C++ prelinker: warning: an error occurred during name decoding`** for `std::__cxx11::basic_string` symbols (about
   20 in the link). Harmless here, but it is a sign of the same name-decoding gap.
4. **`--emit-c` takes no `-I`** (known, `docs/notes/realworld.md`): it cannot preprocess ggml's headers.

## Environment

The qbe backend fails the same way on `origin/main` in this checkout (`tests/cases/eh_exception_ptr.cpp`,
`eh_libstdcxx_throw.cpp`, `eval_order_calls.cpp`, `qbe_gnu_forms.cpp`, and five `tests/c` float128/float16/long double
cases: cproc rejects the qbe-prep output). These are not caused by the driver changes above; the gcc backend passes.
