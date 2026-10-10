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
  `scripts/weak-symbols.rb` emits `.weak` directives for them in the QBE wrapper (data and `extern inline` functions too since the
  multi-TU work, see `docs/notes/multi-tu.md`).

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
     `__aligned_membuf` and `std::aligned_storage`. `scripts/qbe-prep.rb` moves the attribute after the
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
      20 uses. `scripts/qbe-prep.rb` matches exactly that statement and calls `__nfcxx_int3()`; the assembly
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
      (libstdc++'s `atomic_base`). cproc has no atomics, so `scripts/qbe-prep.rb` declares the libatomic
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

## nlohmann/json and {fmt}: third and fourth checks

Both are cloned into `build/realworld` at a pinned commit and built with a single-translation-unit program, run on
both backends, and the program's whole output is compared byte for byte with the host `g++` build of the same
source (`NFCXX_CXX` picks the host compiler). Each script takes about two minutes or less.

| library | pin | script | gcc | QBE |
|---|---|---|---|---|
| [nlohmann/json](https://github.com/nlohmann/json) (MIT) | tag `v3.12.0`, commit `55f93686` | `tests/realworld/run_json.sh`, program `json_main.cpp` | ok (82 output lines match host) | ok (after the fixes below) |
| [{fmt}](https://github.com/fmtlib/fmt) (MIT) | tag `12.2.0`, commit `1be298e1` | `tests/realworld/run_fmt.sh`, program `fmt_main.cpp` | ok, header-only and compiled | skipped (see below) |

`json_main.cpp` parses a document, mutates it, dumps with and without indentation, iterates (iterators, range-for,
`items()`), round-trips through text, CBOR and MessagePack, converts a user struct with `to_json`/`from_json`,
provokes `parse_error` (seven kinds of bad input), `out_of_range`, `type_error` and a failing `from_json`, and covers
number formatting, JSON patch/diff and `flatten`. Exceptions need the EDG EH runtime, so this also exercises
`throw`/`catch` through deeply instantiated templates.

`fmt_main.cpp` covers width, precision, fill, alignment, integer bases, floating point (`e`, `g`, `a`, shortest
round-trip), named and positional arguments, `format_to`, `format_to_n`, `memory_buffer`, `fmt::print` to stdout and a
`FILE*`, user-defined formatters (a `Point`, an enum), ranges/tuples/maps, `FMT_STRING` and `FMT_COMPILE`
compile-time checked formats (EDG accepts the C++20 `consteval` format strings), and eight `format_error` cases.
There are two modes, both one translation unit: `FMT_HEADER_ONLY`, and "compiled" (`-DFMT_COMPILED_UNITY`), where the
library sources `src/format.cc` and `src/os.cc` are `#include`d at the end of the program, so the non-header-only
configuration (extern templates, explicit instantiations, `fmt::output_file` over POSIX `open`) is built without a
second translation unit. (A real second TU would hit the driver bug where two nfcxx-compiled TUs that both use
`std::string` fail to link.)

### What nlohmann/json needed on QBE (the gcc backend needed nothing)

In the order the build hit them. Each is covered by a case in `tests/cases` that fails without the fix:

| first blocker | root cause | fix |
|---|---|---|
| `GNU attribute 'aligned' is not supported here` at `extern const char _ZZNSt19_Sp_make_shared_tag5_S_tiEvE5__tag __attribute__((__aligned__(8)))[16]` | cproc accepts the GNU `aligned` attribute only on struct members (`declaratortypes` passes `align` only there); the old rewrite moved it next to the name, which is wrong for an object | `qbe-prep.rb` (and its oracle) now writes `_Alignas(N)` before the declared name, which cproc takes on objects and members. Case `qbe_json_forms.cpp` |
| `GNU attribute 'aligned' is not supported here` at `struct Over {char c[3]; char __dummy[29];} __attribute__((__aligned__(32)));` | only `std::aligned_storage`'s `{char b[L];}` shape was handled; `struct alignas(32) T` is the general case | the struct-level attribute becomes `_Alignas(N)` on the first member (not a bit-field). Size is rounded up to N, as with GCC |
| `undeclared identifier: __builtin_strcmp` | cproc has few builtins | libc call (`__builtin_memchr` was missing from the oracle's table too; it is in the port, so the oracle is brought level) |
| `undeclared identifier: __atomic_thread_fence` (libstdc++ `shared_ptr`) | cproc has no atomics or fences | `__atomic_thread_fence` and `__atomic_signal_fence` call a weak `mfence; ret` stub from the assembly tail (a full barrier on x86-64 for every memory order) |
| `undeclared identifier: __builtin_huge_val` / `nan` / `isfinite` / `isinf` / `signbit` / `ldexp` / `bswap16` / `bswap32` / `bswap64` | same | small `static` helpers in the prelude (`double` only; `nan("")` ignores the payload argument; `isinf` returns `+1`/`-1` like GCC) and `ldexp` from libm |
| **runtime**: `SIGSEGV` at `movq 0, %rsi` in `std::find_if_not` | QBE: a struct local that is never stored to, passed by value (libstdc++ passes a `_Iter_pred<lambda>` temporary that holds only a dummy `char`). `mem.c` `coalesce()` kills slots with an empty store mask and replaces the `Oargc` operand with a null address on purpose (`/* crash */`). Plain C triggers it: `struct P {char d;}; long f(long a) { struct P p; return g(a, p); }` | `scripts/qbe-uninit-slot.patch`, applied to the QBE copy by `setup-qbe.sh`: such a slot gets a full mask, so it stays allocated and is read as garbage, as with gcc. Case `qbe_uninit_struct_arg.cpp` |
| **runtime**: `terminate()`/`abort` or a segfault right after `std::all_of(first, last, lambda)` returns | cproc: copying a zero-size struct (the closure, passed by value on) emitted one `loadub`/`storeb`, because `funccopy()` runs its loop at least once. The destination is a zero-byte slot, which QBE places at the frame pointer, so `mov %al,0x0(%rbp)` overwrote the low byte of the caller's saved `%rbp` | `scripts/cproc-empty-copy.patch` (after the empty-struct patch): a zero-size copy emits nothing. Case `qbe_empty_struct_copy.cpp` (segfaults without it) |

Both patches only take effect after `scripts/setup-qbe.sh` is run again (CI does).

### {fmt} on QBE: skipped, two cproc limits

`run_fmt.sh` defaults to the gcc backend and prints a skip for `NFCXX_BACKEND=qbe` (set `FMT_QBE=1` to try it anyway).
The first error is cproc's, from `fmt/format.h`'s `uint128_t`:

```
<stdin>:1030:9: error: declaration has no type specifier     (typedef __uint128_t ...native_uint128)
```

Minimal repros for the two limits (both build and run on the gcc backend):

```cpp
typedef unsigned __int128 u128;                                  // cproc has no __int128
u128 mul(unsigned long a, unsigned long b) { return (u128)a * b; }
int main() { return (int)(mul(3, 4) >> 64); }
```

```cpp
long double twice(long double x) { return x * 2; }               // cproc-qbe: long double is not yet supported
int main() { return (int)twice(2.0L); }
```

Neither can be worked around from the driver or the prep pass. {fmt}'s `format_float` is instantiated for `double`,
`float` and `long double` (explicit instantiations in `format-inl.h`, so even an integer-only program contains them), and its
`double` path multiplies through `uint128`. `-DFMT_USE_INT128=0` selects fmt's own `uint128_fallback`, but 12.2.0
then fails in EDG already on the `long double` hexfloat path (`no operator "~"` for `fmt::detail::uint128`: the
fallback lacks it; it also fails with g++), so that does not help. Removing `__SIZEOF_INT128__` for the QBE
backend would have the same result. A faithful `long double` and a 128-bit integer in cproc/QBE are the missing pieces.

Not seen with either library: anything in `scripts/weak-symbols.rb` or the driver.

## C inputs and Lua 5.4

`nfcxx` now takes `.c` inputs (alone or mixed with `.cpp`). A `.c` file skips EDG: with the QBE backend it
goes through `scripts/qbe-cc` (preprocess, `qbe-prep.rb`, cproc, QBE, assemble), with the gcc backend through
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
  register by QBE (stale across `setjmp`/`longjmp`), so `qbe-prep.rb` adds `__nfcxx_keep(&x);` (a call to an
  empty prelude function) after each such declaration, making the address escape. Not covered: volatile
  function parameters, `for` declarations. Test: `tests/c/volatile_setjmp.c`.

### Lua

[Lua](https://github.com/lua/lua) (MIT, pure C) tag `v5.4.9`, commit `312b9efa` (2026-08-07, the newest 5.4.x
tag). `tests/realworld/run_lua.sh` fetches it into `build/realworld/lua` (not vendored), builds the interpreter
from all `*.c` except `luac.c`, `ltests.c`, `onelua.c` (`-lm`), runs `lua -e "print(1+1)"` and
`tests/realworld/lua_test.lua` (string, table, closures, coroutines, `pcall`/`error` over setjmp/longjmp,
integer wraparound). Run by the `Real-world` workflow (`.github/workflows/realworld.yml`), not by `ci.yml`.

| backend | result |
|---|---|
| gcc | built and ran |
| QBE | built and ran (after the three fixes above; the first blocker was the `gnu/stubs-32.h` error, then `multiple types in declaration specifiers` at `_Float32`, then `volatile store is not yet supported` in `ldebug.c`, `ldo.c`, `lstate.c`) |

## `nfcc`: a drop-in `cc` for build systems

`nfcc` (a script next to `nfcxx`) behaves like `cc` for make, rake and autoconf-style probes, on the C
pipeline above. The backend is `NFCXX_BACKEND=qbe|gcc` (default qbe); `NFCC_HOST_CC` names the host compiler
used for preprocessing, dependency files, assembling and linking (default `cc`). It is C only; C++ stays with
`nfcxx`.

- **Modes:** `-c file.c -o file.o` (several sources without `-o` give one object each in the cwd); link of
  `.o`/`.a`/`.so` inputs with `-o`, `-l`, `-L`, `-Wl,*`, `-Xlinker`, `-shared`, `-static`, `-rdynamic`, `-pie`,
  `-pthread` (`.c` inputs on a link line are compiled to temporary objects first); `-fPIC` + `-shared` works on
  both backends (QBE emits GOT-relative code already; gcc gets the flag). `.s`/`.S` go to the host compiler.
  `-x c`, `-x none`, `-x c -` (stdin) are handled.
- **Host-answered:** `-E`, `-M`, `-MM`, `-MG` and `-fsyntax-only` run the host compiler with the original
  arguments (so `-dM`, `-P`, `-Wp,-v` and the like just work); `-dumpmachine`, `-dumpversion`, `-print-*`,
  `-v` alone and `--help` also go to the host compiler. `--version` prints an `nfcc ... (gcc-compatible driver)`
  banner followed by the host compiler's version line.
- **Honoured:** `-std=*` (C only), `-ansi`, `-D`, `-U`, `-I`, `-isystem`, `-iquote`, `-idirafter`, `-include`,
  `-imacros` (the QBE path preprocesses with the host `cc -E`, so these go to it; `scripts/qbe-cc` learned the
  extra forms); dependency files `-MD`, `-MMD`, `-MF`, `-MT`, `-MQ`, `-MP` with `-c` come from the host
  preprocessor (`cc -M`/`-MM`), with gcc's default names (`foo.d` next to `-o foo.o`, target `foo.o`).
- **Also honoured:** `-S` (assembly instead of an object, one `.s` per source, `-o -` for stdout; gcc backend:
  the host compiler's output, QBE backend: QBE's own, so the two differ); `@file` response files, expanded first
  with gcc's rules (whitespace-separated, single/double quotes, backslash escapes, nested `@file`; an unreadable
  file is an error); `-Wa,*` (handed to the assembler, unused with `-S`); `-Wp,` followed by `-D<m>`, `-U<m>`,
  `-I<d>`, `-isystem`/`-iquote`/`-idirafter`/`-include`/`-imacros,<arg>`, `-MD`/`-MMD,<file>`, `-MF`/`-MT`/`-MQ,<arg>`
  and `-MP`, which become the options without the `-Wp,`; any other `-Wp,` item is rejected. On the gcc backend
  `-O0 -O1 -O2 -O3 -Os -Og` (the last one wins; `-O2` when none is given, as before) and `-g*` (none unless asked)
  are passed to gcc. `-Ofast` is rejected (it was silently dropped before).
- **Ignored on purpose:** `-O*` and `-g*` on the QBE backend (no optimisation levels, no debug info), `-W*` (including `-Werror`), `-w`, `-pipe`, `-v` with other arguments,
  `-m64`, `-march=`, `-mtune=`, other `-m<feature>` x86 options, and an allow list of `-f` options that cannot
  change what the program means here (`-fPIC`, `-fvisibility=`, `-fno-strict-aliasing`, `-fwrapv`,
  `-fno-common`, `-fstack-protector*`, `-f(no-)omit-frame-pointer`, `-ffunction-sections`, `-flto`, ...; the full
  list is `fok` in `nfcc`). The gcc backend always adds `-fwrapv -fno-strict-aliasing`, as `nfcxx` does.
- **Rejected with `nfcc: error: ...`, nothing written:** `-m32`/`-mx32`, `-fsanitize*`, `-fopenmp`,
  `-fprofile*`, `--coverage`, `-ffast-math` and friends, `-funsigned-char`, `-fshort-enums`, `-ftrapv`, other
  `-f` options that change semantics or are not in the allow list, `-std=c++*`, `-x c++`, C++ and other non-C
  sources, other `-Wp,*` options, unreadable `@files`, dependency options on a compile-and-link command, and any
  option it does not know.

`tests/c/cc-mode.sh` (both backends, 145 checks) invokes it the way make does: flag soup, a Makefile with
`CC=nfcc`, `-MMD -MP` and `-include *.d` (touching a header rebuilds the dependents), `ar`, `-L`/`-l`, a shared
object, autoconf-style probes, and one check per rejected option.

### Lua through its own makefile

`tests/realworld/run_lua_make.sh` runs `make CC=<repo>/nfcc` with Lua's own `makefile` (the developer's makefile
that ships in the lua/lua repository; same pinned commit as `run_lua.sh`) in a scratch copy of the sources, then
runs `lua -e "print(1+1)"` and `lua_test.lua`. Its warning flags, `-march=native`, `-fno-stack-protector`,
`-fno-common`, `-Wl,-E` all pass through nfcc unchanged; only `MYCFLAGS`/`MYLIBS` are overridden to drop
`-lreadline` (not installed) and keep `-std=c99 -DLUA_USE_LINUX`. `ar`/`ranlib` come from the makefile.

| backend | result |
|---|---|
| gcc | built (`liblua.a`, `lua`) and ran |
| QBE | built and ran |

## mruby

[mruby](https://github.com/mruby/mruby) (MIT) tag `4.0.0`, commit `831da26b9021de0369d17b71b5667e2941a1a32d`
(2026-04-20, the newest non-rc tag; `4.1.0-rc` exists but is a release candidate). `tests/realworld/run_mruby.sh`
fetches it into `build/realworld/mruby` (not vendored), then runs mruby's standard build, `rake all`, with
`tests/realworld/mruby_build_config.rb`: the default gembox, `toolchain :gcc`, and `cc.command` /
`linker.command` set to `nfcc` (`MRUBY_CC`). Ruby 3.3.6 and rake 13.1.0 were already installed (rake's
binary is not on `PATH`; the script finds it through `Gem.bindir`). The build is bootstrapped: it compiles
`mrbc` first and uses that binary to compile the Ruby parts of the core and the gems, so the QBE-compiled
parser and VM run during the build. The resulting `mruby` runs `-e 'puts 1+1'` and
`tests/realworld/mruby_test.rb` (strings, arrays, hashes, blocks, lambdas, `rescue`/`raise`/`ensure` and a
50-deep re-raise (setjmp/longjmp in the VM), `catch`/`throw`, a memoizing `Hash`). Run by the `Real-world` workflow (`.github/workflows/realworld.yml`), not by `ci.yml`.

| backend | result |
|---|---|
| host gcc (control, `MRUBY_CONTROL=1`) | built and ran |
| nfcc, gcc backend | built and ran |
| nfcc, QBE backend | built and ran |

The QBE build of the whole default gembox (core, 60 gems, `mrbc`, `mruby`, `mirb`, `mrdb`) is clean after the
fixes below. These were the first blockers, in the order the build hit them (the first column is the exact text):

| first blocker on QBE | cause | fix |
|---|---|---|
| `<stdin>:2262:10: error: undeclared identifier: __builtin_add_overflow` (`src/backtrace.c`) | `include/mruby/numeric.h` tests `__has_builtin(__builtin_add_overflow)`, which the host preprocessor answers yes to even with `-undef` | `qbe-prep.rb` lowers `__builtin_{add,sub,mul}_overflow` with nested `_Generic` to small helpers, with `int`/`long`/`long long` (signed or unsigned) operands of one type; every other integer mix (literals, `char`/`short`, mixed signedness or width, narrower or wider result) goes through `__nfcxx_ovx`, which computes the exact result in sign and 128-bit magnitude and converts it to `*r` like GCC; a non-integer operand or result links against an undefined `__nfcxx_overflow_unsupported_operand_types`. Cases `tests/c/builtins_overflow_mixed.c` (expected values taken from gcc) and `tests/builtins/overflow.cpp`. Also `__builtin_popcount*`, `ctz*`, `clz*`. Case `tests/c/builtins_overflow.c` |
| `<stdin>:...: error: va_arg with non-scalar type is not yet supported` (`src/error.c`: `va_arg(ap, mrb_value)`; also `src/vm.c`) | cproc/QBE `vaarg` is scalar-only (cproc issue 52); `mrb_value` is a 16-byte struct (or 8 bytes with word boxing) | `scripts/cproc-vaarg-aggregate.patch`, applied by `setup-qbe.sh` after the empty-struct patch: va_arg of a struct/union of at most 16 bytes made only of integers/pointers reads the SysV va_list directly (register save area if `gp_offset <= 48 - size`, else the overflow area). Floats in the aggregate, more than 16 bytes, over-alignment and non-x86_64 keep the error. Case `tests/c/va_struct.c`, which also covers the "one register left" corner and was cross-checked against gcc-compiled callers and callees |
| `undefined reference to 'alloca'` (link of `mrbc`, bison's `y.tab.c`) | without `__GNUC__`, glibc's `<alloca.h>` declares a function; libc has none | `qbe-prep.rb` (C inputs) rewrites `alloca(n)` calls to `__builtin_alloca`. Case `tests/c/alloca.c` |
| `qbe:...: invalid instruction type in truncd` (`mruby-numeric-ext`) | `DBL_MIN` is `((double)2.2250738585072014e-308L)`; cproc types the literal as long double and emits an invalid cast | `qbe-prep.rb` drops the `L` of a literal directly cast to `double`/`float`. Case `tests/c/float_limits.c`. (Finding it also fixed `qbe-prep.rb`'s tokenizer, which split `1e-308` at the sign.) |

Not needed, although feared: computed goto / labels-as-values. `src/vm.c` uses them only under `#ifdef __GNUC__`
(`MRB_USE_VM_GOTO`-style direct threading), and `qbe-cc` preprocesses C inputs without `__GNUC__`, so the VM is
built with the portable `switch` dispatch. `__builtin_expect` is behind `__GNUC__` too (and cproc knows it).
Compared with host gcc, that makes the QBE VM slower; no timing was taken.

Other things the build exposed, not on cproc's side:

- mruby decides "this is Windows" when any directory `/a/` ... `/z/` exists (`for_windows?` in
  `lib/mruby/gem.rb`); this machine has `/x/`, so the default build picked `hal-win-io` and failed on
  `windows.h` with plain gcc already. The build config names the POSIX HAL gems explicitly.
- `rake` with `-j` keeps going on stale objects after a compiler change; delete the build directory when
  `nfcc` or `qbe-prep.rb` changes (the script builds in a fresh temporary directory every time).
- `nfcc` rejected `-Wp,-v - -fsyntax-only`, which mruby's gcc toolchain uses to find the header search
  path; `-fsyntax-only` (and so `-Wp`) is now answered by the host compiler.

**mruby's own test suite (extra, not in `run_mruby.sh`):** `MRUBY_TEST=1 rake test` with the same config
(`conf.enable_test`) builds `mrbtest` and runs the library tests of all gems. QBE backend: 1714 tests, 1704 OK,
0 KO, 1 crash, 9 skipped. Host gcc control: identical numbers. The one crash is `UDPSocket.new => socket` raising
`RuntimeError` in this sandbox (no usable socket), the same with gcc; it makes `rake test` exit 1 before the
`bintest` stage, which was therefore not run on either.

## What remains

- **`va_arg` of aggregates** is only done for integer-class aggregates up to 16 bytes on x86_64. A struct with a
  float/double member (SSE class), over 16 bytes (passed in memory) or over-aligned still stops with cproc's
  error. The cproc change is local to the build copy; it should go upstream (cproc issue 52).
- **Overflow builtins** accept any mix of integer operand and result types; a floating-point or pointer operand or
  result still fails loudly at link time. A mixed call expands to a long `_Generic` expression (the operand text
  is repeated per result type), which is fine for mruby-sized uses but would be slow to compile in a hot macro.
- **`long double`** and `_Complex` are still unsupported by cproc (`mruby-cmath`, which is not in the default
  gembox, needs `_Complex`).
- `nfcc` rejects `-Wp,` items other than the preprocessor options listed above, and does not generate dependency
  files for a compile-and-link command; `-std=c89`/`-ansi` change only the preprocessing (cproc always parses C11 plus
  its GNU subset).
- The QBE backend of `nfcc` ignores `-O*`/`-g`: no optimisation levels and no debug info (assembly from `-S`
  has no `.loc` lines). The gcc backend honours them.

## Next candidates

Projects with no dependencies and their own tests, to find the next gaps: a small compression library in C++, or
another header-only library. Doctest and {fmt} stay on the gcc backend (see the decisions above); nlohmann/json runs on both.
mruby (C) now builds and runs on both backends through `nfcc`; see "What remains" above. Another C project that
uses autoconf (`./configure CC=nfcc`) would be the next test of the `cc`-compatibility of `nfcc`.
