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
  `scripts/cproc-empty-struct.patch`; `scripts/setup-qbe.sh` applies it to the build copy of cproc (`3rd/cproc`
  itself is unchanged). It makes three changes in cproc: an empty struct or union body is accepted (size 0,
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

The qbe path needs the patched cproc: run `scripts/setup-qbe.sh` (it applies `scripts/cproc-empty-struct.patch`)
before testing, and rerun it after pulling a change to the patch.

```
scripts/setup-qbe.sh                               # build/qbe and build/cproc, with the cproc patch
tests/lib/run.sh                                   # both backends
NFCXX_BACKEND=gcc tests/lib/run.sh
./nfcxx --freestanding --backend=gcc tests/lib/span.cpp -o /tmp/span && /tmp/span; echo $?   # 0
./nfcxx --freestanding tests/lib/initializer_list.cpp -o /tmp/il                            # qbe: works
./nfcxx --freestanding tests/lib/optional.cpp -o /tmp/opt && /tmp/opt; echo $?               # qbe: 0
```
