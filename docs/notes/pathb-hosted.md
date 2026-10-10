# Path B on hosted programs

Path B (EDG lowered IL -> typed IR `be/nfcxx_ir.c` -> QBE through `scripts/pathb-qbe-emit.rb`) used to run only freestanding
probes: the harness gave EDG its own `include_c++` and nothing else, so `<new>` failed to open `stddef.h`. It now compiles
programs that use the host C and C++ library headers (gcc 13 here), links them with libstdc++, and passes the same probes
as the gcc backend.

## What changed

- **Header discovery shared with the driver.** `scripts/host-sys.sh` (sourced by `nfcxx` and `scripts/pathb-dump`) prints the
  include directories of the host `g++` (`NFCXX_CXX`, `NFCXX_SYS_INCLUDES`) and its GNU version (`--gnu_version=130000`).
  `pathb-dump` puts the host directories *before* EDG's `include_c++` (as `eccp` orders user and default directories; before,
  EDG's own minimal `<stdexcept>` hid `std::runtime_error`). `--freestanding` or `PATHB_HOSTED=0` gives the old harness.
  `nfcxx --emit-c` uses the same order. `pathb-dump` takes `-I`, `-D`, `-U` (a relative `-I` is made absolute: the front end
  runs in another directory).
- **`scripts/pathb-cc`**: one C++ file to an object (`pathb-dump --ir | pathb-qbe-emit.rb | qbe | cc -c`, `PATHB_KEEP=dir`
  keeps the intermediate files).
- **Driver opt-in**: `NFCXX_PATH=b ./nfcxx ...` (or `--backend=pathb`) compiles every `.cpp` with `pathb-cc`, `.c` files with the
  QBE C path, and links with EDG's runtime (`-lC` first, then `-lstdc++ -lgcc_s -lpthread -lm -latomic`).
  `NFCXX_PATH=b tests/run.sh` runs `tests/cases` through it; `tests/pathb-qbe/hosted.sh` is the CI-able check.
- `scripts/setup-pathb.sh`: `PATHB_EDG_SRC` (EDG checkout elsewhere, for worktrees with an empty `3rd/`), `PATHB_JOBS`.
- `tests/pathb-qbe/run.sh`: links with `-lm -latomic`; `tests/cases/qbe_*.cpp` now run too; `multi/*/` directories may hold
  `.c` files built by the host C compiler (`multi/abi_c`).

## Probes (tests/pathb-qbe/cases)

`hosted_cstdio`, `hosted_cstdlib` (also `<cstring>`), `hosted_new`, `hosted_stdexcept`, `hosted_string`, `hosted_vector`,
`hosted_map` (map, set), `hosted_unordered`, `hosted_algorithm`; and `abi_struct`, `vararg_def`, `base_null`.
The `gaps_*` programs ("Built-ins, atomics, asm" below) are stress probes: `gaps_alloca`, `gaps_overflow`, `gaps_bits`, `gaps_float`,
`gaps_atomic`, `gaps_vaarg`, `gaps_asm`, and the library programs `gaps_function` (std::function, unique_ptr, shared_ptr, weak_ptr),
`gaps_tuple` (tuple, pair, optional, variant, array), `gaps_sort` (sort, stable_sort, partial_sort, ... with lambdas), `gaps_stream`
(string streams, iomanip, std::string), `gaps_thread` (chrono, thread, mutex, atomic, condition_variable, future), `gaps_sync` (C++20
latch/barrier/semaphore/jthread, pmr, complex, locale), `gaps_containers` (deque ... bitset, <bit>, <random>), `gaps_regex`, `gaps_io`
(fstream, filesystem, RTTI, user exceptions), `gaps_cxx20` (ranges, concepts, <=>), `gaps_complex` (`std::complex`: the gcc backend
cannot link `__builtin_cabs`, so this one is checked by exit status only, `// GCC: undefined`). Each prints what it computes and must match the gcc backend byte for byte. All agree with the gcc
backend except `hosted_new` (`// GCC: undefined`): on the gcc backend `new` of a huge size reaches libstdc++'s operator new, which
throws a gcc-ABI `std::bad_alloc` that EDG's exception runtime cannot catch (abort). Path B links `libC.a` first and gets EDG's
operator new, so it behaves. That is a path A bug, found by this probe.

## Gaps found and closed (each has a probe or golden)

| Gap | Fix |
| --- | --- |
| host headers | see above |
| unused globals of dependent type (`__args` packs) and of types the emitter refuses (`__uint128_t`, `_Float128` variable templates) stopped every module | the module loop skips dependent-typed variables; the emitter drops an unreferenced `(extern)` global in pruning and builds its type table only from the globals that stay |
| name tables were linear and limited to 8192 entries (`name table full`) | hashed, growing tables (`ir_tab`) |
| `std::string` literals `L"..."` (wide string data) failed `string data longer than its array` | string data length is in bytes: count x element size |
| `if constexpr`, `if consteval` statements | lowered to the taken branch (as `c_gen_be.c` does) |
| GCC asm labels (`strchr(char*, int) __asm("strchr")` of `<cstring>`) | the symbol is the asm label (functions and variables) |
| `__builtin_*` | `expect`, `constant_p`, `unreachable`, `trap` are values/markers; every other `__builtin_X` with a libc function is a call of `X`; the rest of the family is in "Built-ins, atomics, asm" below |
| inline members of `extern template` classes (`std::allocator<char>::allocate`) had no body (gcc inlines them) | `suppress_inline_body` routines without `definition_for_inlining_only` are emitted `(weak)` |
| derived-to-base pointer conversion of a null pointer trapped (`&p->__b` was checked like a dereference); `std::map` node pointers are null all the time | address-of `p->f` / `*p` does not check `p` |
| compound assignment with operands of different types (`unsigned n; n /= 10UL;`) mixed `unsigned` and `unsigned long` in one operation | computed in the usual-arithmetic-conversions type, converted back |
| empty bases and `[[no_unique_address]]` members shifted the constant list of an aggregate initializer (`std::pair` of `{2,1}` became `(1,0)`) | `is_optimized_empty_base` / `is_optimized_empty_class` are not members |
| base-class subobject fields of reduced size (`__b_N` with the "no tail padding" type) counted as a second member | recognised by name and offset |
| empty class initialized by `{}` (constant 0 of class type) | zero / no item |
| `(void)0` constant | a void value |
| `va_start`, `va_arg`, `va_end`, `va_copy` | `(vastart A)`, `(vaarg T A)`, `(copy 24 ...)`: QBE's `vastart`/`vaarg` use the System V `va_list` that glibc's `vsnprintf` reads |
| structs passed or returned by value used the Path B convention (pointer), not the C one: `div()`, libstdc++'s `_M_need_rehash` returning `std::pair<bool, size_t>` (every `unordered_*` insert) broke | **Aggregates by value** below |
| `__asm__ volatile("int $3")` (doctest) | `raise(SIGTRAP)`; the other asm forms are main's lowering (empty-template barriers) |

### Aggregates by value (C calling convention)

Every struct or class that is a parameter or result gets a module-level `(abi-type "NAME" SIZE ALIGN SHAPE)` form: `(leaf OFF K)...`
with K one of `b h w l s d`, or `(memory)` (more than 16 bytes), `(empty)`, `(unsupported "why")`. Calls spell the arguments
`(byval TYPE ADDR)` and `(sret TYPE ADDR)`. The emitter declares a QBE aggregate type from the leaves and uses QBE's own
System V classification: a parameter is `:tN %p` (the register holds the address of the callee's copy), a result is
`function :tN` returning the address of a buffer the function owns, and the caller copies it to the destination. Unions and
bit-fields classify per eightbyte (INTEGER if any member is, else SSE); a long double member, or an unaligned member, is refused with
the reason. Empty classes are not passed (gcc >= 8). An IR with no `abi-type` keeps the old pointer convention (the hand-written
edge IR in `tests/mruby/pathb-edge`). Non-trivial classes never reach this: EDG's lowering turns them into pointers.
Probes: `abi_struct.cpp` (libc `div`/`ldiv`/`lldiv`, every shape class, function pointer, more arguments than registers),
`multi/abi_c` (a C file compiled by the host cc, called and calling), `hosted_unordered.cpp`.

## Built-ins, atomics, asm (the gaps round)

Everything below has a probe that must print what the gcc backend prints (`// STDOUT: same`, `tests/pathb-qbe/cases/gaps_*.cpp`) and,
where the IR itself is the point, a golden in `tests/pathb-ir` (`builtins.ir`, `vaarg_agg.ir`, `asm_refuse.ir`, `vaarg_ld.ir`; the runner
also checks that the emitter accepts or refuses them as stated).

| Feature | Lowering |
| --- | --- |
| `__builtin_alloca`, `alloca` (declared by `<alloca.h>`, EDG does not apply the macro), `__builtin_alloca_with_align[_and_max]` | New IR node `(alloca SIZE)`, QBE `alloc16` where it stands: the storage lives until the function returns, also from a loop (each execution allocates again, exactly alloca's contract, so a loop that allocates without bound grows the stack as under gcc), blocks never overlap and are 16-byte aligned. An alignment above 16 bytes over-allocates and rounds the address up. VLAs do not interact: the front end lowers them to `__vla_alloc`/`__vla_dealloc` (heap blocks freed at scope exit), so alloca and VLAs can be mixed in one function (`gaps_alloca.cpp`). `setjmp`: the "keep every slot in memory" treatment of a function that calls `setjmp` covers its static slots; alloca blocks are dynamic stack, which `longjmp` restores to the `setjmp` call's stack pointer (blocks allocated after `setjmp` are gone after the jump, as in C), and the pointer variable is an ordinary slot. |
| `__builtin_{add,sub,mul}_overflow`, the `_p` predicates, `__builtin_[su](add\|sub\|mul)[l\|ll]_overflow` | Exact GCC semantics for any mix of integer operand and result types up to 64 bits (signed multiply, mixed signedness and widths, `bool` operands). One integer type with no bool: the textbook tests (`r < a`, `a < b`, `a != 0 && r / a != b`, the sign-xor tests). Otherwise the operands are extended to 64 bits by their own signedness and the exact result is a pair of 64-bit words (add/sub: sum of the sign words and the carry or borrow; mul: product of the magnitudes, `r / a != b` catches a magnitude overflow, negated by the sign mask) that must be the sign extension of its low word and, for a narrower result, equal to its own truncation re-extended. `NFCXX_IR_OVF_GENERAL=1` forces the general scheme everywhere (tested against gcc: `gaps_overflow.cpp` hashes every (A, B, R, op) over boundary values; 6 x 4 x 6 x 3 combinations). The C path has its own reference in `qbe-prep.rb` (`__nfcxx_ovx`). |
| `bswap16/32/64`, `popcount[l\|ll]`, `clz`, `ctz`, `ffs`, `parity`, `clrsb` | Inline straight-line IR (parallel bit sum, smeared-top-bit clz, `popcount(~x & (x - 1))` ctz, ...): no libgcc call, so a freestanding link works too and the results are defined for 0 (clz/ctz of 0 return the width; gcc leaves them undefined). Before, `bswap16` and `parity` were link errors and the others needed libgcc symbols the link line did not always resolve. |
| `expect`, `expect_with_probability`, `constant_p` (0), `unreachable`, `trap` (both abort; gcc's trap is SIGILL), `assume_aligned`, `launder`, `prefetch` (arguments evaluated, nothing else), `object_size` (-1 for types 0/1, 0 for 2/3, the argument is not evaluated; gcc may know the size of a visible object), `is_constant_evaluated` (false at run time) | values or no-ops |
| `isnan`, `isinf`, `isfinite`, `isnormal`, `isinf_sign`, `signbit` (libm `__signbit[f]`), `fpclassify` (libm `__fpclassify[f]`), `isgreater`, `isgreaterequal`, `isless`, `islessequal`, `islessgreater`, `isunordered` | `x - x` separates finite from NaN/infinite; the comparisons are QBE's ordered ones. Before, `<cmath>` classification of a `float` called the double routine (wrong ABI) or an undefined symbol. |
| Non-finite float constants (`NAN`, `INFINITY`, `numeric_limits<>::infinity()`, `HUGE_VAL`) in code and data | `d_inf`, `d_-inf`, `d_nan` (QBE reads them with `strtod`); the NaN is the positive quiet NaN, sign and payload are not in the IR. Before: `refused: non-finite floating constant`. |
| `__atomic_test_and_set`, `__atomic_clear`, `__atomic_thread_fence`, `__atomic_signal_fence`, `__sync_*` (all sized forms) | EDG leaves them as calls nothing exports (libatomic has only the sized `__atomic_*_N`). Lowered to those: test_and_set is `__atomic_exchange_1`, clear a store, a thread fence a locked `__atomic_fetch_or_4` on a private word (a full barrier on x86 and opaque to the compiler), a signal fence `(barrier)`, `__sync_fetch_and_OP_N`/`__sync_OP_and_fetch_N` the `__atomic` forms, the compare-and-swaps use a temporary for the expected value. All seq_cst. `std::atomic_flag`, `atomic_thread_fence`, `std::atomic<T>` of every size, `std::latch/barrier/semaphore` need them (`gaps_atomic.cpp`, `gaps_sync.cpp`). |
| `va_arg` of a struct/class/union by value | Spelled in IR with the System V algorithm and the by-value classification (`ir_abi_collect`): up to 16 bytes with INTEGER/SSE eightbytes come from the register save area when `gp_offset <= 48 - 8 n_int` and `fp_offset <= 176 - 16 n_sse`, otherwise (and for every larger or memory-class aggregate, a `long double` member) from `overflow_arg_area`, which advances by the size rounded to 8. An empty class takes nothing. An aggregate aligned to 16 or more, or a shape the by-value convention cannot describe, stays an `(unsupported ...)` marker. `va_arg` of `long double` is carried in the IR and the emitter refuses it by name (QBE has no 80-bit type). `gaps_vaarg.cpp` crosses `int`/`double`/mixed/`float` pairs/memory structs with registers running out mid-list. |
| inline asm | `pause`, `rep nop`, `rep; nop`, `nop` (with no operands and at most `"memory"`/`"cc"` clobbers) and `__builtin_ia32_pause` are `(barrier)`, an opaque call of an empty module-local function: the instruction has no observable effect, the call keeps its place in the instruction stream. Any other instruction is refused with its text (`refused: (unsupported stmt asm-template "mfence")`; `asm-operands`, `asm-clobbers`, `asm-goto` as before). A fence is not a no-op, so `mfence` and friends are refused rather than lowered to an empty call. |
| other `(unsupported ...)` found by the stress programs | `std::function` from a plain function (the reference-to-function argument `*__f` was *loaded* instead of decayed: segfault); a repeated array initializer (`ck_init_repeat`, `std::bitset`, `T a[N]{}`) and zero fills of more than 128 stores (now `(zero-fill N ADDR)`); `alignas`/`aligned` on a variable (slot and global alignment came from the type; QBE slots are 16-byte aligned at most, so a larger alignment over-allocates and rounds up, and a global's `align` takes any power of two up to 64, the most QBE data accepts: libstdc++'s `__waiter_pool_base` is 64-byte aligned); `__builtin_X` with no library function and no lowering (`frame_address`, `return_address`, `ia32_*`, ...) is now `(unsupported builtin X (no lowering))` instead of a link error. |
| EDG front end assertion (`lower_il.c:10294`, "internal error ... in lower_routine") | Reached by `std::visit` with a functor and by `<chrono>`/`<thread>` in C++20 and later (`struct _Guard` of `basic_string.tcc`). The Path A build never gets there. The fork take-cheeze/edg-compiler (branch `nfcxx/ignored-routine`, tracked as `3rd/edg`) skips a routine the back end ignores (a prototype instantiation) instead of asserting, as `lower_routine_list` already does. |

## Known limits (still failing)

- **Exceptions thrown by libstdc++.so** (`vector::at`, `std::function` called empty (`bad_function_call`, checked), `stoi("x")`
  (checked), `std::__throw_*` in general, huge `new` on the gcc backend) use the gcc unwinder; EDG's
  setjmp/longjmp exception ABI cannot catch them (abort, "terminate() called by the exception handling mechanism"). Throws that
  the headers contain (`optional::value`, bad `variant` access, `throw` expressions in user code) work. The same holds
  for `std::current_exception`, `exception_ptr`, `throw_with_nested`: libstdc++.so keeps that state in its own exception globals.
  Path A has the same limit. User-code throws, `std::runtime_error` etc. constructed in user code, and EDG's `operator new` work
  (`gaps_io.cpp` throws and catches a dozen kinds).
- `long double`, see below. It reaches programs through `std::uniform_real_distribution` / `normal_distribution` /
  `generate_canonical` (`std::log(long double)`), `std::format` (the long double formatter) and `<cmath>` overloads: those functions
  are refused (or abort with `--long-double=trap`). `_Float128`/`__int128` types are refused when a kept function uses them.
- `__builtin_object_size` always reports "unknown" (gcc -O0 knows the size of a visible local); `__builtin_trap` aborts (SIGABRT)
  where gcc raises SIGILL; the NaN constant is always the positive quiet NaN; `va_arg` of an aggregate aligned to 16 bytes and the
  frame/return-address built-ins stay markers.
- VLAs use one global malloc pool, which is not thread safe (see stage 3); `alloca` does not.

## long double

QBE has no 80-bit type and the emitter refuses any IR that mentions `long_double`. For hosted programs the header paths that reach
it are few. doctest: `std::ostream::operator<<(long double)` (inline in `<ostream>`), `doctest::toString(long double)`,
`toStreamLit<long double>` and `IsNaN<long double>`: four functions, none run by the test driver. tinyxml2 never mentions it.

**Decision: no silent `long double` = `double`.** A double fallback changes the value, the size and the calling convention (x87
class in memory, `printf("%Lf")`, `strtold`, `ostream::_M_insert<long double>` in libstdc++.so), so a program that really uses
it would be wrong without notice. Instead the opt-in `--long-double=trap` of the emitter (`PATHB_LONG_DOUBLE=trap` for `pathb-cc`,
`NFCXX_LONG_DOUBLE=trap` for the driver) turns every function that mentions `long_double` into a stub that aborts when it runs, and
drops globals of that type. Results stay correct for programs whose long double code does not run (doctest below), and
the failure is loud (SIGABRT) when it does. Without the option the module is refused as before.

## Real-world programs

- **tinyxml2** (pinned, `tests/realworld/run.sh` sources): `NFCXX_PATH=b ./nfcxx -I<src> tests/realworld/tinyxml2_main.cpp <src>/tinyxml2.cpp`
  gives exit 12, same as the gcc and QBE backends; no long double on its header paths. `tests/pathb-qbe/hosted.sh` checks it.
- **doctest** (pinned, `tests/realworld/run_doctest.sh` source): builds with `NFCXX_LONG_DOUBLE=trap` and gives the expected exit 2
  (23 assertions pass, 2 deliberate failures reported) now that thread_local dynamic initialization is lowered. Without the
  option it is refused at the first long double function.
- Lua, mruby are C programs: not Path B.
