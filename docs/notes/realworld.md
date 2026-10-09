# Real-world programs

First real third-party project: [tinyxml2](https://github.com/leethomason/tinyxml2) (zlib license),
pinned to commit `8224e427`. `tests/realworld/run.sh` fetches it into `build/realworld` (not vendored)
and builds it with `tinyxml2_main.cpp`, expecting exit code 12.

## Result

- **gcc backend: passes.** The whole library (`tinyxml2.cpp`, 3k lines) compiles and the driver runs
  correctly.
- **QBE backend: passes.** Two things had to work: empty struct definitions (the cproc patch, see
  `docs/notes/freestanding.md`) and COMDAT functions. EDG marks inline and template instantiations
  `__attribute__((__weak__))`; cproc drops that, so the per-object copies collided at link time.
  `scripts/weak-symbols.py` emits `.weak` directives for them in the QBE wrapper.

## What it took

- **Hosted headers:** tinyxml2 includes `<cctype>`, `<cstdio>`, `<string.h>`, and similar. The driver
  now adds the host C++ library include directories and the host GNU version by default
  (`host_sys_includes` in `nfcxx`). `--freestanding` still turns this off. `NFCXX_CXX` picks the host
  compiler and `NFCXX_SYS_INCLUDES` overrides the list.
- **Nothing else** was needed for this library on the gcc backend.

## doctest: second check

[doctest](https://github.com/doctest/doctest) (MIT, single header) pinned to tag `v2.4.12`, commit
`1da23a3e` (2025-04-28, the newest v2.4.x tag). `tests/realworld/run_doctest.sh` fetches it into
`build/realworld/doctest`. `tests/realworld/doctest_main.cpp` is the driver: several `TEST_CASE`s with
`SUBCASE`s, `CHECK`, `REQUIRE`, and `CHECK_THROWS_AS`, plus two deliberate failures. A listener reads
the failed-assertion count (`Context::run()` only returns 0 or 1), and `main` returns it, so it expects
exit code 2. Hosted path (no `--freestanding`).

- **gcc backend: passes.** Exit 2, with the 2 deliberate failures and 23 passing assertions.
- **QBE backend: xfail.** The build gets past the four gaps below, then stops at the next cproc limit.
  The chain, in the order cproc hits them in doctest's C output:
  1. **Fixed:** `GNU attribute 'aligned' is not supported here`. Two shapes from libstdc++'s
     `__aligned_membuf` and `std::aligned_storage`. `scripts/qbe-prep.py` moves the attribute after the
     member name (cproc accepts it there), and turns a struct-body attribute into `_Alignas` on the first
     member when the size is a multiple of the alignment.
  2. **Fixed:** `typedef __bf16 ...` (cproc has no `__bf16`). The same pass maps `__bf16` and the
     `_Float16`/`_Float32`/`_Float64`/`_Float128` types that `<numbers>` uses (the four missing from this
     list; `<numbers>` is pulled in by libstdc++'s `<map>`). `_Float32` and `_Float64` become `float` and
     `double` (same IEEE formats on x86-64). The others become 2- or 16-byte structs with no arithmetic,
     so a real use is a compile error rather than a wrong value. Literals become exact bit patterns.
  3. **Fixed:** `GNU attribute 'constructor' is not supported here` (global constructors, `__sti_*`).
     EDG puts `__attribute__((__constructor__))` on each static-initializer declaration. The pass removes
     the attribute and lists the function in `.init_array` in the assembly tail.
  4. **Fixed:** thread_local with dynamic initialization. EDG emits top-level `__asm__(".global _ZTHx")`
     and `__asm__("_ZTHx = __tls_init")`. cproc rejects top-level asm, so the pass moves them to `.globl`
     and `.set` in the assembly tail, with `.weak` when the `_ZTWx` wrapper is COMDAT.
  - Regression cases: `tests/cases/qbe_gnu_forms.cpp` (gaps 1, 2, 4) and `tests/cases/qbe_global_ctor.cpp`
    (gap 3). Both fail on the previous `qbe-cc` and pass on both backends.
  - **Not fixed, next blockers** (found after gaps 1 to 4; each is a separate change):
    - *Inline asm* in doctest's `DOCTEST_BREAK_INTO_DEBUGGER`: `__asm__ volatile("int $3\n" : :)`, 20 uses.
      cproc has no inline asm: the message is `inline assembly is not yet supported`. This is the current xfail.
      A fix is a call to a weak `int3; ret` stub in the assembly tail. Not done.
    - *Builtins* cproc does not know (its table is `3rd/cproc/scope.c`): `__builtin_memcpy`, `memmove`,
      `memset`, `memcmp`, `strlen` (libc names with the same prototypes), `__builtin_isnan`, `__builtin_clzl`,
      and `__builtin_mul_overflow(x, C, &x)` with `C` an unsigned long constant (20 uses, all this shape).
      Not done. The same kind of rewrite as gaps 1 to 4 would cover them.
    - *Sized atomics* `__atomic_load_N`, `__atomic_store_N`, `__atomic_fetch_add_N` (libstdc++'s
      `atomic_base`): cproc has no atomics. libatomic from GCC 13 exports these. A fix is to declare them and
      link `-latomic` on the QBE link. Not done.
    - *`long double`*: `cproc-qbe: long double is not yet supported`. Doctest's `toString(long double)` and
      `IsNaN<long double>` need it. QBE has no 80-bit float, so there is no faithful lowering. Mapping it to
      `double` would change results silently.
    - *Pointer compatibility*: `base types of pointer assignment must be compatible or void` on EDG's
      temporaries in doctest's `MultiLaneAtomic`. This was seen after items 5 to 7 were lowered in a scratch
      copy with `long double` replaced by `double`. Not analysed further.
  - So `tests/realworld/run_doctest.sh` stays an xfail on QBE. Removing it needs at least the `long double`
    decision and the pointer-compatibility work above.

Fixes made for this check (the driver, not the back ends):

- **libm on the hosted link** (`nfcxx`): `--c_to_obj_lib=m`. Without it, `log10` from `<cmath>` is an
  undefined reference. g++ links libm implicitly, so this matches it. `--freestanding` is unchanged.
- **gcc `-fkeep-static-functions`** (`nfcxx`): EDG's static `__tls_init` is referenced only through the
  top-level asm alias above. `gcc -O2` drops it and leaves `undefined reference to '__tls_init'`. The flag is
  gcc-specific. Only gcc was tested as the C compiler.

Also seen, not fixed: `nfcxx --emit-c` does not pass user `-I` options to `cpfe`, so `#include` of a
`-I` directory fails in emit mode (`cannot open source file "doctest/doctest.h"`). The gcc build of doctest
also prints many `unrecognized GCC pragma` warnings from the EDG front end (doctest's `#pragma GCC
diagnostic`). They do not affect the result.

## Next candidates

Projects with no dependencies and their own tests, to find the next gaps: a JSON or XML parser or a
small compression library in C++. The QBE gaps above (inline asm, builtins, atomics, `long double`) are
the next ones to fix before doctest or a larger C++ library can pass on QBE.
mruby is C, so it needs a C front-end mode first, which nfcxx does not have yet.
