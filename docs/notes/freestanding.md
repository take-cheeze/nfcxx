# Freestanding headers (`lib/`)

Headers for a C++ library that does not use hosted libc++ or libstdc++ headers. Everything lives in the
private inline namespace `std::__nfcxx`, except `initializer_list` (see "Compiler constraints"). Status: a subset,
tested with `tests/lib/run.sh`.

## Enabling it

```
./nfcxx --freestanding hello.cpp -o hello          # default backend (qbe)
./nfcxx --freestanding --backend=gcc hello.cpp -o hello
```

Off by default; the default driver path is unchanged. `--freestanding` does three things:

1. `--no_standard_includes -I<repo>/lib` to eccp: EDG's default include directories are not searched, so only
   `lib/` provides headers. A hosted header is rejected: `#include <cstdio>` gives "cannot open source file".
2. `--gnu_version=130000` to the g++ front end (unless `--gnu-version=N` is given). Without it, EDG rejects
   `__is_same` and `__builtin_bit_cast` in g++ mode (`docs/notes/builtins.md`).
3. Nothing about linking: programs still link with the usual host libraries. "Freestanding" here means no hosted
   headers, not a no-libc link. The panic helper calls libc `write` and `abort` through the C ABI.

`--dialect=clang` is also available; `NFCXX_DIALECT` sets the default.

Note on include paths in this checkout: `build/edg-base/include` is a relative symlink (`../../../../include_c++/`)
that resolves to `/home/include_c++` from the prebuilt tree, so default g++ mode finds no std headers at all.
Freestanding mode does not use it. The C++ headers EDG ships (`3rd/edg/include_c++`) contain no `<cstdio>`
anyway, so default mode has no hosted library headers either.

## Targets (`--target=NAME`)

`--target=NAME` lays the program out for an EDG target instead of the build host: `linux_aarch64`, `linux_armv7`,
`linux_riscv64`, `linux_riscv32`, `linux_i686`, `win64`, `win32` (the `lib_*` tables of the EDG base; `linux_x86_64` is
the host's). It is valid with `--freestanding --emit-c` only, and the other combinations are refused:

```
./nfcxx --freestanding --emit-c --target=linux_aarch64 prog.cpp > prog.c
clang --target=aarch64-linux-gnu -ffreestanding -c prog.c -o prog.o     # the generated C is for the target
```

- **What the target sets.** The sizes and alignments of EDG's tables, and the predefined macros of `lib_<target>`
  (`__aarch64__`, `__riscv`, `__arm__`). Plain `char` is unsigned on `linux_aarch64`, `linux_armv7`, `linux_riscv32`
  and `linux_riscv64`: the driver passes `--unsigned_chars` for those four. EDG's `defines.h` says signed for aarch64 and
  armv7 (`TARG_HAS_SIGNED_CHARS_*`), which is wrong for their Linux ABIs; `clang -dM` for each triple gives
  `__CHAR_UNSIGNED__`. The EDG base is not patched for this.
- **What it does not do.** The generated C is not compiled, linked or run by nfcxx: with a target the compile and
  link paths are refused, because the host's C compiler and libraries are the host's. Compile the C with a cross
  compiler for the target. There are no hosted headers for a target (`--freestanding` only).
- **Checked by `tests/target/run.sh`:** for `linux_aarch64`, `linux_riscv64` and `linux_armv7`, a probe with
  `static_assert`s for pointer, `long` and `long double` sizes, `char` signedness and the target's macro is accepted by
  EDG, and the host refuses the same file; each of the 11 `tests/lib` programs is emitted for the target and compiled by
  `clang --target=<triple>`. The refusals (no `--freestanding`, no `--emit-c`, unknown name) are checked too.
- **Run under emulators:** each layout probe is built by the target's cross gcc (static) and run under qemu-user
  (`qemu-aarch64`, `qemu-arm`, `qemu-riscv64`, exit 0 expected: `// RUN-QEMU: 0`). The probes are EH- and template-free,
  so they link. `.github/workflows/emulators.yml` runs them nightly and on changes to the related files. The Hexagon
  checks (`hexagon.yml`) also run nightly. Only these probes are run, not the `tests/lib` programs (they need the EH
  runtime, see Windows below).
- **Known gap: floating-point constants.** EDG computes `long double` with the host's type (`setup-edg.sh` says so for an aarch64 host). On an x86-64 host that is
  the 80-bit x87 type, but the aarch64 and riscv64 `long double` is 128-bit IEEE quad, so a folded constant can differ in
  its last bits from what the target computes. Not tested here; the fix is EDG's host floating-point configuration
  (`src/includes/cmake_defines.h`, as `scripts/setup-edg.sh` sets it on an aarch64 host).

## Windows (`--target=win64`, MinGW-w64 and wine)

`win64` is EDG's Windows configuration (LLP64). Its own predefined-macro table is Microsoft's and lacks the gcc type macros
`lib/cstdint` uses, so with MinGW-w64 installed `scripts/setup-edg.sh` replaces that table with MinGW's own `gcc -dM`
output (`scripts/win-predef.sh`). Without MinGW the table is EDG's, and the generated C does not compile with MinGW.

```
./nfcxx --freestanding --emit-c --target=win64 prog.cpp > prog.c
x86_64-w64-mingw32-gcc -O2 -fwrapv -fno-strict-aliasing prog.c -o prog.exe
wine prog.exe
```

- **Checked:** `tests/target/win64_probe.cpp` (static asserts for `long` = 4, `void*` = 8, signed `char`, and the
  `lib/cstdint` types, then a computed result) is built this way and run under wine: exit 42. `tests/target/run.sh` runs it
  when MinGW and wine are installed and skips otherwise. Of the `tests/lib` programs, `limits` links and runs too; it fails
  with exit 1 because it asserts a 64-bit `long`, which LLP64 does not have. That is a test that is LP64-only, not a bug.
- **Not working yet: linking.** Most `tests/lib` programs need EDG's C++ runtime (`__curr_eh_stack_entry`,
  `__internal_rethrow`, `__eh_curr_region`), which Linux takes from the host-built `libC.a`. A MinGW build of it means
  compiling `3rd/edg/lib_src` with MinGW's headers, and EDG's default mode rejects those headers (`__debugbreak` and
  other MinGW declarations). Also `--emit-c` does not run the prelinker, so a template the program uses (for example
  `sum_indices` in `tests/lib/utility.cpp`) is an unresolved extern at link time. The Linux path gets both from `eccp`.
- **Wrong in EDG's `win64` table: `long double`.** EDG has it as 8 bytes (`TARG_SIZEOF_LONG_DOUBLE_win64` in `defines.h`, a
  compiled-in constant, so the driver cannot change it). MinGW's gcc uses 16 bytes (x87). Code whose layout or `sizeof`
  depends on `long double` is wrong for MinGW. `win64_probe.cpp` avoids `long double`. The fix is in EDG's source, not here.
- **Not checked:** the wine run covers exit codes only; `write` and the panic path are not exercised under wine, and no
  hosted (libstdc++, MSVCRT-free) program is built for Windows.

## Headers

| header | provides | notes |
|---|---|---|
| `cstddef` | `size_t`, `ptrdiff_t`, `nullptr_t`, `std::byte` with operators, `to_integer`, `offsetof` | `size_t` comes from `__SIZE_TYPE__`. No `::size_t` (no `stddef.h`). |
| `cstdint` | `int8_t`..`uint64_t`, least/fast/`intptr_t`/`intmax_t` types, `INT*_MIN/MAX`, `UINT*_MAX` | Names in `std::__nfcxx` only, no global names. |
| `type_traits` | `integral_constant`, `bool_constant`, `enable_if`, `conditional`, `void_t`, `conjunction`/`disjunction`/`negation`, `is_same`, `remove_*`, `add_const`, `add_pointer`, `decay`, category traits (`is_void`, `is_integral`, `is_floating_point`, `is_arithmetic`, `is_pointer`, `is_reference`, `is_const`, `is_volatile`, `is_array`), builtin-backed `is_class`, `is_union`, `is_enum`, `is_empty`, `is_final`, `is_pod`, `is_base_of`, `is_trivially_copyable`, `is_trivially_destructible`, `is_constructible`, `is_trivially_constructible`, `underlying_type`; `_v` variables | Not provided: `is_function`, `is_member_pointer`, `common_type`, `invoke`, `is_nothrow_*`, `is_assignable`, `is_aggregate`, `is_polymorphic`, `long double` category. |
| `utility` | `move`, `forward`, `swap`, `exchange`, `as_const`, `pair` (with `==`, `!=`, `<`, `swap`), `make_pair`, `integer_sequence`, `index_sequence`, `make_integer_sequence`, `make_index_sequence` | Sequences are built by recursive halving, not `__make_integer_seq` (the g++ front end rejects that builtin). |
| `initializer_list` | `std::initializer_list` (pointer + size), `begin`, `end` | Declared in namespace `std` itself (see constraints). |
| `new` | placement `operator new`/`operator delete` (and `[]`), `std::launder` | No heap allocation (no `operator new(size_t)`). |
| `limits` | `numeric_limits` for `bool`, `char`, all standard signed/unsigned integer types | No floating point yet. |
| `array` | `std::array` (aggregate), `at` (panics), `get<I>`, comparisons, `fill`, `swap` | `N == 0` keeps one unused element. `operator[]` is unchecked, as in the standard. |
| `span` | `span<T, Extent>` (pointer + size for both extents), construction from arrays, `std::array`, conversion to `span<const T>` | Checked `operator[]`, `front`, `back`. `first`/`last`/`subspan` return dynamic-extent spans (the runtime overloads only). No `as_bytes`. |
| `optional` | `optional<T>`, `nullopt`, `make_optional`, copy/move, assignment, `emplace`, `reset`, `swap`, `value`, `value_or`, comparisons | `value()` on an empty optional panics. Storage is a union (no `alignas`). Value constructor and accessors are `constexpr`; copy/move and assignment are not. |
| `string_view` | `basic_string_view<char>`, `char_traits<char>`, `find`, `substr`, `compare`, `starts_with`, `ends_with`, `remove_prefix`/`remove_suffix`, `operator==` etc. | `at`, `substr` and `operator[]` panic on bad indexes. No wide views. |
| `nfcxx_panic` | `std::__nfcxx::__panic(const char*)` | Writes `nfcxx panic: <msg>` to fd 2 with `write`, then `abort()`. Replaces exceptions for now. |

## Compiler constraints found

- **`std::initializer_list` must be declared directly in `namespace std`.** With the same class in
  `std::__nfcxx`, `f({1, 2})` fails with "no instance of constructor ... initializer_list". The front end
  recognises the braced-list type by its namespace. Checked on both backends.
- **Placement new is not a constant expression.** `optional`'s value constructor therefore initializes the union
  member in its mem-initializer list, so `static_assert(optional<int>(5).value() == 5)` works.
- **`__builtin_trap` is not usable on qbe** (cproc: undeclared identifier). The panic helper uses `abort` instead.
- **`__make_integer_seq` and `__type_pack_element` are rejected in g++ mode** (even at GNU 13). Accepted in clang mode.
- Trait builtins that EDG rejects in g++ mode without `--gnu-version`: `__is_same`, `__builtin_bit_cast`.

## cproc (qbe) limitations seen

- **Empty class definitions (fixed by a local cproc patch).** EDG emits every instantiated empty class as
  `struct X {};`, and cproc rejected that ("no type in struct member declaration"). This covers trait metafunctions
  (`remove_reference<int&>`), `char_traits<char>`, `nullopt_t` and `integer_sequence<>`. The patch is
  `cproc-empty-struct`, a commit on take-cheeze/cproc branch `nfcxx-asan-combined` (the pin of `3rd/cproc`); `scripts/setup-qbe.sh`
  builds cproc from that pin, so the patch is in the build. It makes three changes in cproc: an empty struct or union body is accepted (size 0,
  alignment 1, the GNU C rule that gcc follows); a zero-size object, or an array of them, gets a zero-byte
  allocation (cproc assumed only arrays are zero-size); and a constant-length array of zero-size elements is a
  static array, not a VLA. Regenerate the patch if `3rd/cproc` moves. An older `build/cproc` without the patch fails on
  the empty-class tests again.
- **Layout of empty classes (decision).** On the qbe path an empty class has size 0 and alignment 1, the same as
  the gcc backend's `struct X {}`, so both backends agree on storage. C++ gives a complete empty object size 1.
  Size 1 was tried first, as a padding member rewrite (`struct X { char pad; }`) in `scripts/qbe-cc` (a token-aware
  filter, not a sed). It compiled, but the `utility` test then segfaulted: EDG leaves the temporary for a
  by-value empty argument such as `index_sequence<>{}` uninitialized (an empty class has nothing to store). QBE
  reads an uninitialized aggregate argument as a fatal error by design (`mem.c`, slot coalescing, `CON_Z /* crash */`).
  A zero-size argument uses no register, so QBE never reads it. Size 0 is therefore the layout that works.
  Known gap, not changed here: EDG folds `sizeof` with C++ rules (`sizeof(E)` is 1 and `struct { E e; int x; }`
  is 8), while the C struct has 4 bytes of storage because the empty member takes 0. Both backends behave the same
  way, and no test asserts `sizeof` of an empty class. Matching C++ fully needs layout decisions in EDG's output
  (padding for empty members, empty-base optimisation), which is out of scope.
- **`alignas` on a local variable** is emitted as `__attribute__((__aligned__(16)))`, which cproc rejects
  ("GNU attribute 'aligned' is not supported here"). The lib uses unions for storage; the `new_launder` test does too.
- **Builtins**: see `docs/notes/builtins.md` (`__builtin_mem*`, overflow family, `__builtin_trap`).
- Not exercised by the lib: `long double`, `volatile`, inline asm (cproc rejects them, as noted in `docs/DESIGN.md`).

## Tests

`tests/lib/*.cpp` (`// EXPECT:` format; static_assert plus runtime checks, span/array/optional/string_view behaviour,
`initializer_list` loops). `tests/lib/run.sh` runs each on both backends unless `NFCXX_BACKEND` is set.

Current result: gcc 11 of 11 pass, qbe 11 of 11 pass (the five empty-class tests no longer have `xfail` markers).
The `panic` test expects exit status 134 (SIGABRT): the abort path is tested as well as the in-range path.

## Reproduce

The qbe path needs the patched cproc: run `scripts/setup-qbe.sh` (it builds the pinned cproc, which has `cproc-empty-struct`
as a commit on take-cheeze/cproc branch `nfcxx-asan-combined`) before testing, and rerun it after moving the pin.

```
scripts/setup-qbe.sh                               # build/qbe and build/cproc, with the cproc patch
tests/lib/run.sh                                   # both backends
NFCXX_BACKEND=gcc tests/lib/run.sh
./nfcxx --freestanding --backend=gcc tests/lib/span.cpp -o /tmp/span && /tmp/span; echo $?   # 0
./nfcxx --freestanding tests/lib/initializer_list.cpp -o /tmp/il                            # qbe: works
./nfcxx --freestanding tests/lib/optional.cpp -o /tmp/opt && /tmp/opt; echo $?               # qbe: 0
```
