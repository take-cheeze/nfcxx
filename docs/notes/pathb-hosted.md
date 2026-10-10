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
`hosted_map` (map, set), `hosted_unordered`, `hosted_algorithm`; and `abi_struct`, `vararg_def`, `base_null`. All agree with the gcc
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
| `__builtin_*` | `expect`, `constant_p`, `unreachable` are values/markers, `trap` is SIGILL (`(trap)`, below), `object_size` is a constant (below); `mul/add/sub_overflow` (unsigned, and signed add/sub, one integer type) are lowered with the textbook tests; `clz/ctz/popcount/bswap32/64` call the libgcc routines; every other `__builtin_X` with a libc function is a call of `X` |
| inline members of `extern template` classes (`std::allocator<char>::allocate`) had no body (gcc inlines them) | `suppress_inline_body` routines without `definition_for_inlining_only` are emitted `(weak)` |
| derived-to-base pointer conversion of a null pointer trapped (`&p->__b` was checked like a dereference); `std::map` node pointers are null all the time | address-of `p->f` / `*p` does not check `p` |
| compound assignment with operands of different types (`unsigned n; n /= 10UL;`) mixed `unsigned` and `unsigned long` in one operation | computed in the usual-arithmetic-conversions type, converted back |
| empty bases and `[[no_unique_address]]` members shifted the constant list of an aggregate initializer (`std::pair` of `{2,1}` became `(1,0)`) | `is_optimized_empty_base` / `is_optimized_empty_class` are not members |
| base-class subobject fields of reduced size (`__b_N` with the "no tail padding" type) counted as a second member | recognised by name and offset |
| empty class initialized by `{}` (constant 0 of class type) | zero / no item |
| `(void)0` constant | a void value |
| `va_start`, `va_arg`, `va_end`, `va_copy` | `(vastart A)`, `(vaarg T A)`, `(copy 24 ...)`: QBE's `vastart`/`vaarg` use the System V `va_list` that glibc's `vsnprintf` reads |
| structs passed or returned by value used the Path B convention (pointer), not the C one: `div()`, libstdc++'s `_M_need_rehash` returning `std::pair<bool, size_t>` (every `unordered_*` insert) broke | **Aggregates by value** below |
| `__asm__ volatile("int $3")` (doctest) | `raise(SIGTRAP)`; the other asm forms are in "Inline asm" below |

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

## Known limits (still failing)

- **Exceptions thrown by libstdc++.so** (`vector::at`, `std::__throw_*`, huge `new` on the gcc backend) use the gcc unwinder; EDG's
  setjmp/longjmp exception ABI cannot catch them (abort). Path A has the same limit. User-code throws, `std::runtime_error` etc.
  constructed in user code, and EDG's `operator new` work.
- `__builtin_alloca`, signed multiply-overflow and mixed-type overflow builtins, `bswap16`, aggregate `va_arg`: an IR gap
  marker / link error when reachable. Asm statements outside the list in "Inline asm" below.
- `long double`, see below. `_Float128`/`__int128` types are refused when a kept function uses them.
- **128-bit bit-fields** (`unsigned __int128 f : 100`, or `: 20`): the layout of a structure that has one is right and its
  other members work, but any access to the field is refused (`refused: type __uint128_t`; a width over 64 also has the marker
  `bit-field-wider-than-64-bits`). It needs `__int128` values, which neither the IR nor QBE has (no 128-bit arithmetic, conversion
  or calling convention); `tests/mruby/pathb-edge/r_bitfield128.ir`. Not done: that is `__int128` support as a whole.
- **`__builtin_object_size`** answers only for the address of a known object (below); any pointer that was loaded, passed or
  returned is unknown (-1, or 0 for types 2 and 3), as in gcc without optimization. `__builtin_dynamic_object_size` is the same
  (it does not see the size of a VLA or an allocation). TYPE 1 of the address of a member of a *global* structure is -1: the front
  end folds `&g.m` to the address of `g` plus an offset and the member is lost (a local structure, `ls.a[1]` and `&ls.m`, is exact).
- **VLA subscripts** are checked only when the subscript base is the VLA variable itself and the number of elements one index
  step covers is a constant: not `m[n][k]` with a run-time `k`, and not a pointer parameter or a pointer derived from the array
  (pointers carry no length, as for fixed arrays). Checked traps abort (SIGABRT) like the other checks.
- **`alias`/`weakref`**: the alias target has to be defined in the same unit (as in gcc), on x86-64 ELF only (the aliases are
  `.set` lines in the assembly). `weakref` without a target name (`__attribute__((weakref))` with `alias`) and `ifunc` are not
  handled. The gcc backend cannot alias a static function (`tests/pathb-qbe/cases/alias_static.cpp`).

## Inline asm

QBE has no inline assembly, so Path B accepts the asm statements whose effect it can write itself and refuses every other with its
reason (`refused: (unsupported stmt asm-template | asm-operands | asm-clobbers | asm-goto)`). `ir_asm_stmt` in `be/nfcxx_ir.c`
normalizes the template (blanks and case ignored, `;` and newline alike, `%%` read as `%`), then:

| Template | Lowering |
| --- | --- |
| empty, `nop`, `pause`, `rep; nop` | nothing; a memory clobber (and any basic `asm`) is `(barrier)`, a call of an empty module-local function |
| `mfence`, `lfence`, `sfence`, `lock; addl $0,(%rsp)` (and `or`, `addq`, `orq`, `0(%rsp)`) | `(fence)`: a call of `__pathb_fence`, a weak function with `mfence` that `--append-weak` puts into the assembly; a full fence is stronger than `lfence`/`sfence`, so sound, and an opaque call is a compiler barrier too |
| `ud2` | `(trap)`: SIGILL |
| `int $3`, `int3` | `raise(SIGTRAP)` |
| `rdtsc`, `lfence; rdtsc`, `mfence; rdtsc` | `(rdtsc)`: a call of `__pathb_rdtsc` (`rdtsc; shlq $32,%rdx; orq %rdx,%rax`); the outputs must be exactly `"=a"` and `"=d"`, integers of 4 or 8 bytes, the value is the low or high 32 bits; with no operands the counter is read and dropped |

Operands are accepted only on an empty template (the compiler-barrier idioms of benchmark libraries: `asm volatile("" : : "r,m"(v) : "memory")`,
`asm volatile("" : "+r,m"(v) : : "memory")`, `asm volatile("" : "+x"(d))`) and on `rdtsc`. An input is evaluated once and dropped
(a memory-only constraint takes the address, an aggregate needs a memory alternative); a `+X` or untied `=X` output keeps its value
(the empty template writes nothing, so the old value is a valid unspecified value); an output tied to an input (`"=r"(x) : "0"(y)`,
both scalars of one type) receives the input, all inputs being read before any output is stored; an output that may be memory
adds a barrier. Refused (`asm-operands`): flag outputs (`=@cc..`), x87 constraints (`t`, `u`), an output that is not an lvalue,
more than 10 operands, operands on a fence, `ud2` or `int $3`, a tie among alternatives, a tie to a `+` output or to a different type.
Refused (`asm-template`): any other instruction (`cpuid`, `rdtscp`, `xchg`, `lock; xadd`, `pause` followed by anything, ...).
Refused (`asm-clobbers`): a register clobber on an otherwise acceptable asm, even an empty one. Refused (`asm-goto`).
The helpers are x86-64 code. Probes: `asm_barrier.cpp`, `asm_ext.cpp` (with `// ASM-COUNT:` checks that the fences and barriers are
really calls), `traps/asm_ud2.cpp`; the refusal is in `tests/pathb-ir/gaps.cpp` (`cpuid`), `pathb-edge/r_unsupported_asm*.ir`.

## `__builtin_trap`, `__builtin_object_size`, aliases

- `__builtin_trap` is `(trap)`: QBE's `hlt`, which its amd64 back end writes as `ud2`. The process dies of SIGILL (exit 132) like
  gcc's, not SIGABRT (`traps/builtin_trap.cpp`, `// TRAP-EXIT: 132`). `__builtin_unreachable` reached still aborts (SIGABRT).
- `__builtin_object_size(P, TYPE)` is folded when the lowering runs: P is the address of a local or global variable, a member,
  an element at a constant index, a constant offset, through pointer casts that add no offset; the result is the bytes from P to the
  end of the object (TYPE 0, 2) or of the member (TYPE 1, 3); a past-the-end or negative offset gives 0. The pointer is not
  evaluated, as in gcc. Unknown is -1 for TYPE 0 and 1, 0 for 2 and 3 (`builtin_objsize.cpp`; it compares with the gcc backend).
  Before, the call went to a nonexistent function `object_size` and failed at link time.
- `__attribute__((alias("t")))` and `weak, alias`, and `weakref("t")`, on functions and objects: see `pathb-stage3.md`, last section.

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
