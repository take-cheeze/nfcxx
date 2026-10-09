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
- **QBE backend: xfail.** The build stops in cproc. The chain, in the order the errors show up:
  1. `error: GNU attribute 'aligned' is not supported here`. EDG emits `__attribute__((__aligned__(N)))`
     for libstdc++'s `__gnu_cxx::__aligned_membuf` (the storage of `std::map` and other node containers),
     in two shapes: after an array member (`unsigned char _M_storage[40] __attribute__((...));`) and after
     a struct body (`struct X {char __dummy[8];} __attribute__((...));`, from `std::aligned_storage`).
     cproc accepts the attribute only after a bare identifier. Proposed fix: EDG emits `_Alignas(N)` on the
     member, or the QBE wrapper rewrites those two shapes to `_Alignas(N)` (cproc accepts `_Alignas`).
     Tried in a scratch copy: both rewrites clear this error, and it moves to 2.
  2. `error: declaration has no type specifier` on `typedef __bf16 _ZN9__gnu_cxx12__bfloat16_tE;`. cproc
     has no `__bf16`. Proposed fix: drop or map that typedef in the wrapper.
  3. `error: GNU attribute 'constructor' is not supported here`, on the `__sti_...` static initializer
     for `REGISTER_LISTENER` and the test-case registrations. cproc defines `ATTRCONSTRUCTOR` but no
     declaration accepts it. Repro: `int f() { return 1; } int g = f();` fails with the same error on QBE
     and passes on gcc. Proposed fix: lower namespace-scope dynamic initialization in the QBE path, for
     example by emitting `.init_array` entries from the wrapper. Larger than the others.
  4. thread_local with dynamic initialization (doctest uses it). EDG emits a top-level
     `__asm__(".global _ZTH<name>")` and `__asm__("_ZTH<name> = __tls_init")`; cproc rejects them with
     `error: expected declaration or function definition`. Repro: `thread_local int g = f();`. Proposed fix:
     move those asm lines into the `.s` (`.globl`, `.set`) in the wrapper, as `weak-symbols.py` does for
     `.weak`.

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
small compression library in C++. The QBE gaps above (global constructors, `aligned` on members, thread_local)
are the next ones to fix before a larger C++ library can pass on QBE.
mruby is C, so it needs a C front-end mode first, which nfcxx does not have yet.
