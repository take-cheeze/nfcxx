# Compiler builtins: what EDG accepts and what runs

Probe for the builtins that libc++ and libstdc++ use (type traits, memory and bit operations, overflow
checks, `__make_integer_seq`, `__builtin_bit_cast`, ...). Two different questions are answered separately:

- **EDG accepts**: the front end (`cpfe`) parses and type-checks the builtin, in three modes:
  `g++` (the driver default, GNU version unset), `g++ --gnu-version=130000` (GCC 13 emulation), and `clang`.
- **runs under qbe / gcc**: the generated C is compiled by cproc->QBE (`qbe`) or by gcc, and the program's exit
  code matches the value checks in the test (`// EXPECT: N`). "Compiles" alone is not counted as working.

## Table

Front-end columns from `tests/builtins/fe_matrix.sh`. Runtime columns from `tests/builtins/run.sh`
(`ok` = test passes, `xfail` = known failure with the reason in the test header).

| builtin | EDG accepts (g++ / g++ gnu13 / clang) | runs under qbe | runs under gcc | notes |
|---|---|---|---|---|
| `__is_same` | rejected / OK / OK | ok (`traits_predicates`) | ok | g++ mode needs `--gnu-version` (tested 40700: still rejected; 130000: accepted). |
| `__is_class`, `__is_enum`, `__is_union`, `__is_empty`, `__is_final`, `__is_pod` | OK / OK / OK | ok (`traits_predicates`) | ok | `__is_pod` is deprecated in C++20 but accepted. |
| `__is_trivially_copyable` | OK / OK / OK | ok (`traits_construct`) | ok | |
| `__is_trivially_constructible` | OK / OK / OK | ok (`traits_construct`) | ok | Variadic form `(T, Args...)` works (used by the lib). |
| `__is_trivially_destructible` | OK / OK / OK | ok (`traits_construct`) | ok | |
| `__is_constructible` | OK / OK / OK | ok (`traits_construct`) | ok | A user-declared copy constructor suppresses the implicit default constructor; the test checks this. |
| `__is_base_of` | OK / OK / OK | ok (`traits_relations`) | ok | A class is its own base (checked). |
| `__underlying_type` | OK / OK / OK | ok (`traits_relations`) | ok | Only the fixed-underlying-type cases are asserted; the default type of an unscoped enum is implementation-defined. |
| `__builtin_launder` | OK / OK / OK | ok (`launder_addressof`, lib `new_launder`) | ok | |
| `__builtin_addressof` | OK / OK / OK | ok (`launder_addressof`) | ok | Bypasses an overloaded unary `operator&` (checked). |
| `__builtin_memcpy`, `__builtin_memmove`, `__builtin_memset`, `__builtin_memcmp` | OK / OK / OK | **FAIL**: `undeclared identifier: __builtin_memcpy` (same for the other three). `xfail` in `mem_ops` | ok (`mem_ops`) | EDG emits the name unchanged; cproc's builtin table (`build/cproc/scope.c`) does not contain it. |
| `__builtin_unreachable` | OK / OK / OK | ok (`control_flow`) | ok | cproc knows this name. |
| `__builtin_expect` | OK / OK / OK | ok (`control_flow`) | ok | cproc knows this name. |
| `__builtin_add_overflow`, `__builtin_sub_overflow`, `__builtin_mul_overflow` | OK / OK / OK | **FAIL**: `undeclared identifier` (`xfail` in `overflow`) | ok (`overflow`) | Not in cproc's table. |
| `__builtin_add_overflow_p` (and `_p` forms) | OK / OK / **FAIL** (`identifier`) | ok (standalone probe with constant arguments; EDG folds it, so no name reaches cproc; non-constant arguments not probed) | ok | Clang mode rejects it. The `overflow` test also uses the three builtins above, so it is `xfail` on qbe for them. |
| `__builtin_clz`, `__builtin_ctz`, `__builtin_popcount` (+ `l`, `ll`) | OK / OK / OK | ok (`bits`) | ok | |
| `__builtin_trap` | OK / OK / OK | **FAIL**: `undeclared identifier: __builtin_trap` (`xfail` in `trap_compile_only`) | compiles; the call is in an unreached branch, so the program is not run to trap | Trap is not run in any test (it would abort the process). The lib panic helper calls `abort` instead (`docs/notes/freestanding.md`). |
| `__builtin_is_constant_evaluated` | OK / OK / OK | ok (`constant_eval`) | ok | Gives `true` only inside constant evaluation. A call in a non-constexpr function is warned about as "always false", which is correct. |
| `__builtin_FILE`, `__builtin_LINE`, `__builtin_FUNCTION` | OK / OK / OK | ok (`source_loc`) | ok | |
| `__make_integer_seq` | **rejected** ("is not a template") / rejected / OK | ok with `--dialect=clang` (`integer_seq`) | ok with `--dialect=clang` | The g++ front end does not accept it even with `--gnu-version=130000`. The lib builds `index_sequence` by recursion instead. |
| `__type_pack_element` | **rejected** / rejected / OK | ok with `--dialect=clang` (`integer_seq`) | ok with `--dialect=clang` | Same as `__make_integer_seq`. |
| `__builtin_bit_cast` | **rejected** / OK / OK | ok (`bit_cast`) | ok | Needs `--gnu-version` in g++ mode, like `__is_same`. Works in constant expressions. |
| `__builtin_offsetof` | OK / OK / OK | ok (`offsetof`) | ok | cproc knows this name; the test compares against the real layout. |

## Summary

- Everything that EDG accepts in g++ mode with `--gnu-version=130000` runs correctly on the gcc backend.
- On the **qbe** backend, every builtin that is not one of cproc's builtins fails at the C-compile step, not in
  the front end: the four `__builtin_mem*` functions, the overflow family (`_p` excepted), and `__builtin_trap`.
  Fixing this needs either a lowering in our own IR (Path B) or an explicit mapping in `scripts/qbe-cc`
  (for example to libc calls, which would be a behavioural change for `__builtin_trap`).
- The g++ front end rejects `__is_same`, `__builtin_bit_cast`, `__make_integer_seq` and `__type_pack_element`
  at the default GNU version. `--gnu-version=130000` fixes the first two, and the clang dialect accepts all four.
  The default driver is unchanged; the freestanding mode (`--freestanding`) sets GCC 13 emulation.
- Not builtins, but found while probing (details in `docs/notes/freestanding.md`): cproc rejects empty class
  definitions (`struct X {};`, which EDG emits for instantiated classes such as trait metafunctions and empty
  types), and it rejects `__attribute__((aligned))` on local variables (`alignas` on a local). The builtin probes
  avoid both, so they pass on qbe; the lib tests that hit them are `xfail` on qbe.

## Reproduce

```
tests/builtins/run.sh                   # both backends; NFCXX_BACKEND=qbe|gcc to pick one
tests/builtins/fe_matrix.sh             # front-end columns (g++ / g++ gnu13 / clang)
./nfcxx --gnu-version=130000 --backend=qbe tests/builtins/mem_ops.cpp -o /tmp/x   # reproduce the qbe failure
./nfcxx --dialect=clang --gnu-version=130000 --backend=gcc tests/builtins/integer_seq.cpp -o /tmp/x && /tmp/x; echo $?
```
