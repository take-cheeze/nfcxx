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
    - **Fixed:** *inline asm* in doctest's `DOCTEST_BREAK_INTO_DEBUGGER`: `__asm__ volatile("int $3\n" : :)`,
      20 uses. `scripts/qbe-prep.py` matches exactly that statement and calls `__nfcxx_int3()`; the assembly
      tail defines it as a weak `int3; ret` stub. Any other inline asm still fails with cproc's
      `inline assembly is not yet supported`. Regression case: `tests/cases/qbe_int3_break.cpp`.
    - **Fixed:** *builtins* cproc does not know (its table is `3rd/cproc/scope.c`). `__builtin_memcpy`,
      `memmove`, `memset`, `memcmp` and `strlen` are renamed to the libc functions, with prototypes in the
      prelude. `__builtin_isnan` and `__builtin_clzl` call small helpers. `__builtin_mul_overflow(x, C, &x)`
      with `C` an unsigned long constant (20 uses, all this shape) calls a checked-multiply helper. Other
      builtin uses are left alone and still fail. Regression case: `tests/cases/qbe_builtins_libc.cpp`.
      `tests/builtins/mem_ops.cpp` now passes on QBE, so its `XFAIL-qbe` marker is stale (the runner reports
      an XPASS until the marker is removed).
    - **Fixed:** *sized atomics* `__atomic_{load,store,exchange,compare_exchange,fetch_OP,OP_fetch}_{1,2,4,8}`
      (libstdc++'s `atomic_base`). cproc has no atomics, so `scripts/qbe-prep.py` declares the libatomic
      functions of the same name (GCC 13's libatomic exports them; the prototypes follow its ABI, and
      EDG passes GCC's six arguments to `compare_exchange`). The QBE link in `scripts/qbe-cc` adds
      `-latomic`; gcc is unchanged. The 16-byte forms are left out (they need `__int128`). Regression case:
      `tests/cases/qbe_atomics.cpp`.
    - *`long double`*: `cproc-qbe: long double is not yet supported`. Doctest's `toString(long double)` and
      `IsNaN<long double>` need it. QBE has no 80-bit float, so there is no faithful lowering. Mapping it to
      `double` would change results silently.
    - *Pointer compatibility*: `base types of pointer assignment must be compatible or void` on EDG's
      temporaries in doctest's `MultiLaneAtomic`. This was seen after items 5 to 7 were lowered in a scratch
      copy with `long double` replaced by `double`. Not analysed further.
  - **Decision: doctest is checked on the gcc backend only.** `tests/realworld/run_doctest.sh` defaults to gcc,
    and asking for `qbe` prints a skip with the `long double` reason. The QBE work above stays: the gaps it
    fixed are covered by their own cases in `tests/cases`. Revisit if QBE gains a faithful `long double`.

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

## C inputs and Lua 5.4

`nfcxx` now takes `.c` inputs (alone or mixed with `.cpp`). A `.c` file skips EDG: with the QBE backend it
goes through `scripts/qbe-cc` (preprocess, `qbe-prep.py`, cproc, QBE, assemble), with the gcc backend through
`gcc -c -O2 -fwrapv -fno-strict-aliasing`. `-I`, `-D`, `-U` reach both the C compiler and (unchanged) eccp;
`-l`/`-L`/`.o`/`.a` go to the link. With any `.cpp` the objects are linked by eccp (EDG's runtime); a C-only
program needs no EDG build and is linked by the C compiler. `--trace` records a `C input: <file>` span per file.
`tests/c/run.sh` covers it (5 programs per backend, including a mixed `extern "C"` one; all pass on both).

Hand-written C includes real glibc headers, which needed three things in `scripts/` (all active only for
`.c` inputs, via `NFCXX_C_INPUT=1`, so EDG's generated C is processed as before):

- **Preprocessing:** `qbe-cc` runs `cc -E -undef`, which also removes `__x86_64__` and `__SIZE_TYPE__`; the
  first error was `gnu/stubs.h:7:11: fatal error: gnu/stubs-32.h: No such file or directory`. For C inputs it
  now pre-defines the host's macros (`cc -dM -E`), minus the GCC-identity ones (`__GNUC__`, ...). Without
  `__GNUC__` glibc uses no GNU extensions, which suits cproc.
- **`typedef float _Float32;`** from `<bits/floatn.h>` collided with qbe-prep's `_Float32` mapping
  (`multiple types in declaration specifiers`). qbe-prep drops those typedefs.
- **`volatile` stores:** `cproc-qbe: volatile store is not yet supported` (Lua's `lua_longjmp.status`,
  `lua_State.hookmask`, `CallInfo.u.l.trap`). qbe-prep drops `volatile` for C inputs. cproc already emits
  volatile loads as plain loads, and QBE does not touch memory accesses of address-taken objects, so this is
  sound for struct members and globals. A volatile local whose address is never taken would be promoted to a
  register by QBE (matters for `setjmp`); that gap existed for loads before.

### Lua

[Lua](https://github.com/lua/lua) (MIT, pure C) tag `v5.4.9`, commit `312b9efa` (2026-08-07, the newest 5.4.x
tag). `tests/realworld/run_lua.sh` fetches it into `build/realworld/lua` (not vendored), builds the interpreter
from all `*.c` except `luac.c`, `ltests.c`, `onelua.c` (`-lm`), runs `lua -e "print(1+1)"` and
`tests/realworld/lua_test.lua` (string, table, closures, coroutines, `pcall`/`error` over setjmp/longjmp,
integer wraparound). Not in the GitHub workflow.

| backend | result |
|---|---|
| gcc | built and ran |
| QBE | built and ran (after the three fixes above; the first blocker was the `gnu/stubs-32.h` error, then `multiple types in declaration specifiers` at `_Float32`, then `volatile store is not yet supported` in `ldebug.c`, `ldo.c`, `lstate.c`) |

### What mruby would additionally need

I could not read mruby's repository: it is not in this session's allowed GitHub repositories, and I was told
not to clone it. The following is from memory and **not verified**:

- mruby builds with `rake` (a `Rakefile` plus `build_config.rb` and `lib/mruby/build.rb`), i.e. Ruby is
  needed on the host, and the build is bootstrapped: `mrbc` (the compiler) is built first, then used to
  generate C from the mrblib `.rb` files (`mrblib.c`, gem `gem_init.c`), plus the `yacc`/bison-generated
  `mrbgems/mruby-compiler/core/y.tab.c` (checked in in recent versions, so bison is probably optional).
- The build driver chooses the C compiler from `build_config.rb` (`conf.cc.command`, flags); nfcxx would be
  set as `cc` and linker. Its flags (`-std=gnu99`, `-Wall`, `-DMRB_...`) would have to be tolerated or
  ignored; the driver has no passthrough of arbitrary gcc flags yet (`-std=`, `-W*`, `-O*`, `-c`, `-MMD`
  are not handled; `nfcxx` compiles and links in one call, with no `-c` mode).
- mruby's C uses `setjmp`/`longjmp` (or C++ exceptions with `MRB_USE_CXX_EXCEPTION`), `volatile`, `inline`
  functions and computed goto / `__builtin_expect` in the VM; the last two need a cproc check.

The nfcxx work needed is thus a `-c`/`-o file.o` driver mode and gcc-flag tolerance so rake can drive it,
or a hand-written file list once the generated files exist (generate them with the host `gcc` build, then
compile that tree with nfcxx).

## Next candidates

Projects with no dependencies and their own tests, to find the next gaps: a JSON or XML parser or a
small compression library in C++. Doctest stays on the gcc backend (see the decision above).
mruby is C: the `.c` input mode now exists; see the mruby notes above for what is still missing.
