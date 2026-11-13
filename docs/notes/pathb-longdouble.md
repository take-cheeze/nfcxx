# Path B: long double

QBE has no 80-bit type (its types are `w l s d`), cproc refuses `long double`, and until now the Path B emitter refused any
IR that mentioned it (`refused: type long_double`; `--long-double=trap` turned the functions that use it into aborting
stubs). That blocked `std::uniform_real_distribution<long double>`, `normal_distribution`, `generate_canonical`,
`std::complex<long double>`, `<cmath>` overloads for `long double`, `istream >> long double` and everything in libstdc++
that is instantiated for it. This note describes the replacement: `long double` values live in memory in the x86-64 System V
layout, every operation is a call of a helper that gcc compiled, and the odd calling convention of the type (results in
`st(0)`) is bridged by small assembly thunks. Nothing is approximated: results are the ones the x87 unit gives gcc
(`tests/pathb-qbe/cases/longdouble_*.cpp` print hex floats and compare with the gcc backend byte for byte).

Decision, as before: there is **no silent `long double` = `double`**. A construct that is not supported is a named refusal
(section 7), never a wrong value.

## 1. Representation

A `long double` is an object of 16 bytes, aligned to 16: the 80-bit x87 extended format in the low 10 bytes
(`mantissa:64 | sign+exponent:16`, little endian), 6 bytes of padding. This is EDG's layout (`sizeof` 16, `alignof` 16)
and the ABI's, so libc, libm and libstdc++.so read and write the same bytes (`printf("%Lf")`, `strtold`,
`ostream::_M_insert<long double>`, `std::to_chars`, ...).

In the IR (`be/nfcxx_ir.c`) the type is `(array 16 unsigned_char)` with alignment 16 (`nf_ld_blob` makes the type printer
spell it that way in IR mode only; the stage 1 IL dump still says `long_double`). The value of an expression of that type is
**the address of a 16-byte object**, as for an aggregate: `ir_is_memval(t)` is true for aggregates and for `long double`,
`ir_is_float(t)` is false for it, so no float code path can take it by mistake. Consequences:

- A variable is its own object, a read (`ir_load`) copies it into a fresh temporary so that the value does not change when
  the variable does (`x++` returns the old value), a store is `(copy 16 DST SRC)`.
- No IR node mentions a `long double` scalar type any more; the emitter needs nothing for the arithmetic. The `long_double`
  entry of `(layout ...)` stays, and a hand-written IR that does mention the scalar type is still refused
  (`tests/mruby/pathb-edge/r_longdouble.ir`).
- The padding is zeroed by every helper, so `memcmp` and hashing see the same bytes as long as the object was written by one.

Constants are two 64-bit stores into a temporary (`mantissa`, then `sign+exponent`) taken from EDG's own value (its host
`long double`, so infinity, NaN, denormals and values beyond `double` come out right); a static initializer is two
`(scalar OFF unsigned_long ...)` items. No new IR form is needed.

## 2. Operations

Every operation is `(eval (call void &"__nfcxx_ld_NAME" DST A B))` or `(call int &"__nfcxx_ld_NAME" A B)` on operands that
are addresses. The helpers are in `be/nfcxx_ldrt.c` (plain C compiled by gcc, so the arithmetic is x87 arithmetic):

| IR source | helper |
| --- | --- |
| `+ - * /`, unary `-`, `++`/`--`, compound assignments | `add sub mul div neg` (`ir_x87_arith`; `x++` is `x + 1`) |
| `< <= > >= == !=` | `lt le gt ge eq ne`, return 0 or 1; false for an unordered pair, true for `!=` |
| condition, `!`, `&&`, `\|\|`, `?:`, conversion to `bool` | `nz` (`x != 0`; a NaN is true) |
| integer to long double | `from_s64`, `from_u64` (narrower types are widened first with `iconv`) |
| float, double to long double | `from_f32`, `from_f64` |
| long double to float, double | `to_f32`, `to_f64` (round to nearest like the hardware) |
| long double to an integer of BITS bits | `to_s`, `to_u`: truncate toward zero, **abort on NaN and on a value that does not fit** (the `cf2i` rule of the IR for float and double) |
| `va_arg(ap, long double)` | `vaarg` (reads 16 bytes of the overflow area with gcc's own `va_arg`) |
| `__builtin_fpclassify`, `isnormal`, `isgreater` ... `isunordered` | `fpclassify isnormal gt ge lt le isunordered` |
| `__builtin_isnan/isinf/isfinite/signbit` on a long double | glibc's `__isnanl __isinfl __finitel __signbitl` (they take it in memory) |

Mixed expressions need nothing more: EDG already converts both operands to the common type with explicit cast nodes, which
become the conversions above. Compound assignment of a `long double` to an `int` (`i += 2.5L`) computes in long double and
converts back, like `ir_common_type` does for double.

Not lowered (IR gap markers, so the emitter refuses the function): `~`, `%`, shifts, bit operations on a `long double`
(invalid C++ anyway), and a conversion between `long double` and a pointer.

## 3. Calling convention

x86-64 System V classes a `long double` as **X87**: an argument is passed in memory (16 bytes on the stack, 16-aligned),
a result is returned in `st(0)`; a `_Complex long double` is **COMPLEX_X87**: memory for arguments, `st(0)` (real part) and
`st(1)` (imaginary part) for the result. QBE can pass the first (an opaque 16-byte aggregate is memory class, which is what
`(abi-type "__nfcxx_ld" 16 16 (memory))` declares, and `printf` varargs work the same way) but it cannot read or write the
x87 stack. So:

- **Arguments** are `(byval (struct "__nfcxx_ld") ADDR)` at the call and `(param %N "x" (byval (struct "__nfcxx_ld")))` in
  the definition, which is the existing aggregate-by-value mechanism (the callee gets the address of its copy).
- **Results**: a function whose result is a `long double` or `_Complex long double` is defined, in the IR, as
  `__nfcxx_ldr_F` (F is its symbol): an ordinary function returning `void` with **one more pointer parameter, last**, that
  receives the result (for a variadic function, first, since nothing can follow `...`). Calls to it write into a temporary
  and read it back. This is the convention inside Path B: direct calls of a function defined in the translation unit,
  calls through function pointers, virtual calls, `std::function`, templates, lambdas. The address of such a function
  (`&F`, a vtable slot) is `__nfcxx_ldr_F`.
- **Thunks** connect that to the C convention. They are x86-64 assembly, which QBE cannot be given, so the emitter leaves a
  marker comment in the QBE IL for each one that live code needs and `pathb-qbe-emit --append-weak` (already run on every
  object for the `.weak` lines) turns the markers into assembly appended to the file QBE wrote:
  - `(x87-thunk call "F" INTS STACK)` -> `__nfcxx_x87c_F(args..., dst)`: copies the stack arguments into its own frame, calls
    `F`, `fstpt` the result into `dst`. The IR calls this for every `F` that the translation unit does not define (libm's
    `sqrtl`, `strtold`, `powl`, `frexpl`, ..., another Path B unit's function) and uses it as the address of such an `F`
    (`std::function<long double(long double)> f = sqrtl`). `callc` does the same for a `_Complex long double` result
    (`cexpl`, `cpowl`): `st(0)` and `st(1)` into the two halves of a 32-byte object.
  - `(x87-thunk entry "F" global|weak INTS STACK)` -> `F` itself, for every `F` that Path B defines with external linkage: it
    allocates the buffer, calls `__nfcxx_ldr_F`, loads the result into `st(0)` (`entryc`: both). So C code, libstdc++ and other
    Path B units call a Path B `long double` function by its normal name.
  - INTS is the number of integer registers the parameters use and STACK the bytes of stack arguments (long doubles and
    large structs); the thunk takes the extra pointer from the next integer register, or from the stack word after the
    stack arguments when the six registers are taken, copies the stack arguments (alignment preserved), and touches
    nothing but `r11` and that register. INTS and STACK are computed by `ir_x87_param`, the System V classification
    restricted to what the thunks know (integers, pointers, float, double, long double, structs larger than 16 bytes).
- **EDG's own runtime** (`libC.a`: `__c99_complex_long_double_multiply`, `_add`, `__c99_long_double_to_clong_double`) returns
  a `_Complex long double` through a hidden pointer like any struct; those are called with the ordinary `(sret ...)`
  convention, selected by name (`ir_x87_rout_kind`), and are the reason `std::complex<long double>` `*` and `/` work.

Examples, from `tests/pathb-ir/longdouble_ir.ir`:

```
(x87-thunk call "strtold" 2 0)                 ; strtold(const char*, char**): two integer registers, no stack
(x87-thunk entry "_Z5scaleei" global 1 16)     ; scale(long double, int): one integer register, 16 bytes of stack
(function "__nfcxx_ldr__Z5scaleei"
  (ret void)
  (params (param %0 "x" (byval (struct "__nfcxx_ld"))) (param %1 "k" int) (param %2 "__ldret" (ptr (array 16 unsigned_char))))
  ...
(eval (call void &"__nfcxx_x87c_strtold" ... $"tmp"))
```

### Pointers

The address of a routine that returns a long double (`ir_rout_addr`) is its C-convention symbol, not the trailing-pointer
form: `&F` is `F`, the entry thunk ir_function defines (a static F has a local one, kept with F's body), or the C symbol of
a routine defined elsewhere. Only direct calls use `__nfcxx_ldr_F` and `__nfcxx_x87c_F`. A call through a pointer passes the
arguments, the result pointer and the pointer itself to `__nfcxx_x87i_KEY` (`icall` in the IR), which copies the stack
arguments, takes the callee from the register after the result pointer (or the stack word after the arguments), calls it
with the C convention and stores `st(0)` at the result pointer (`icallc` for `_Complex long double`, `st(0)` and `st(1)`).
KEY is `I<integer registers>S<stack bytes>` of the function type's parameters. A virtual call is an indirect call: the
vtable slot holds the entry. Prune keeps a static F's body when a kept function refers to its entry name.

## 4. What works (tests)

All of these run on Path B and print what the gcc backend prints (`// STDOUT: same`) unless noted.

| Area | Test |
| --- | --- |
| arithmetic, comparisons (NaN, infinity, signed zero), conversions to and from every integer type, float, double, bool, compound assignment, `++/--`, `?:`, `&&`, `!`, constants, raw bytes | `tests/pathb-qbe/cases/longdouble_ops.cpp` |
| globals with static initializers, arrays, members, classes by value (32 bytes, memory class) and results, unions, static locals, references, `new[]`, `std::vector`, `std::map`, lambdas, `unique_ptr`, templates | `longdouble_mem.cpp` |
| 1 to 10 long double arguments, mixed with integers beyond the six registers and doubles beyond the eight, function pointers, virtual functions, `std::function`, `qsort` callbacks, varargs taking and returning long double, libm and libc through the thunks, `frexpl`/`modfl` with pointers | `longdouble_call.cpp` |
| `<cmath>`: every overload, classification, `numeric_limits`, C++17 special functions, `complex` arithmetic | `longdouble_cmath.cpp` |
| `operator<<`/`>>`, `stold`, `to_string`, `to_chars`, `from_chars`, `printf`/`snprintf`/`sscanf`/`swprintf` with `%Lf %Lg %La` | `longdouble_io.cpp` |
| `uniform_real_distribution`, `normal_distribution`, `generate_canonical` and the other real distributions | `longdouble_random.cpp` |
| `std::complex<long double>`: `abs arg polar exp log sqrt pow sin cosh` (libm `c*l` functions, `callc` thunks) | `longdouble_complex.cpp` (EXPECT only: Path A cannot build it) |
| C compiled by gcc calls Path B and is called by it (both directions, `_Complex long double` too) | `tests/pathb-qbe/multi/abi_ld/` |
| `std::atomic<long double>` (generic `__atomic_*` on 16 bytes, `__builtin_clear_padding`) | `longdouble_atomic.cpp` (EXPECT only: Path A cannot build it) |
| NaN and out-of-range long double to an integer abort | `tests/pathb-qbe/traps/longdouble_to_int.cpp`, `longdouble_nan_to_int.cpp` |
| the IR text of all of it | `tests/pathb-ir/longdouble_ir.ir` (golden), `tests/mruby/pathb-edge/x87_thunks.ir` and `e_x87_*.ir` (emitter, Python oracle identical) |

Exceptions with a `long double` operand (`throw 1.5L; catch (long double)`) and dynamic initialization with a libm call
(`long double g = sqrtl(2)`) were also checked by hand.

## 5. Build and link

`scripts/pathb-ldrt` builds `build/pathb-ldrt/libnfcxxld.a` from `be/nfcxx_ldrt.c` (`cc -O2 -fPIC`) on first use and prints
its path. Every Path B link adds it after the objects: the driver (`nfcxx`, `NFCXX_PATH=b`) and `tests/pathb-qbe/run.sh`.
`scripts/pathb-cc` produces an object only, so a program that calls it by hand adds `$(scripts/pathb-ldrt)` to its link line.
A program that never touches a long double does not pull a member out of the archive. The harness (`setup-pathb.sh`) does
not build or include it. `--long-double=trap` / `NFCXX_LONG_DOUBLE=trap` stay for the IR forms that still mention the scalar
type (hand-written IR); the doctest build no longer needs them.

## 6. Why this design

- **Soft-float on the host unit rather than software arithmetic.** The helpers use the hardware x87 unit through gcc, so
  rounding, the NaN payloads, denormals, the exceptions flags and the control word are exactly gcc's; a pure software
  `__addtf3` would need the same effort again and could not be checked against the hardware. The price is one call per
  operation (a tight `long double` loop is several times slower than gcc's inline `fadd`), which Path B accepts everywhere
  else too (volatile accesses are calls as well).
- **IR level, not emitter level.** The lowering is in `nfcxx_ir.c`, one implementation, so the Ruby emitter and its Python
  oracle changed only for the thunk markers (about 80 lines each, byte-identical output checked by `tests/mruby/run.sh`).
  The IR stays target neutral in the sense of stage 2: a different back end gets a 16-byte object and ordinary calls.
- **A trailing result pointer, not `sret` first.** The first-argument convention would shift every register argument by one
  in the thunk; the trailing one leaves them where they are and the thunk only has to find one more slot.
- **Thunks in assembly, generated.** They are the one place that needs the x87 stack; they are tiny, signature independent
  apart from two numbers, and only emitted for what live code uses, so a program without `long double` links nothing new.

## 7. Limits and named refusals

Each is a refusal at compile or link time or a documented difference; none gives a wrong result silently.

- **Function pointers** hold the C-convention address (see "Pointers" below): `&F` is the entry `F` for a Path B function (a
  static one has a local entry, `(x87-thunk entry "F" local ...)`), and `F` itself for a function defined elsewhere. A call
  through a pointer goes through the indirect thunk `__nfcxx_x87i_KEY` (`__nfcxx_x87ic_KEY` for `_Complex`), so C code and
  libstdc++ can call what Path B made, and Path B can call what they made. Two refusals remain, named in the IR:
  `(unsupported variadic function returning long double)` for the address of a variadic routine defined here (it has no
  C-convention entry), and `(unsupported call through a pointer to a variadic function returning long double)` (nothing can
  follow `...` in the indirect call). A direct call of a variadic routine defined elsewhere goes through a thunk of the call's shape (next item); its
  address is its C symbol.
  `tests/pathb-qbe/multi/ldr_ptr` (C calls Path B's pointers and the reverse) and `cases/ldr_ptr_ir.cpp`.
- **Signatures the thunks cannot describe.** The thunks know integers, pointers, float, double, long double and structs
  larger than 16 bytes as parameters (`ir_x87_param`). A parameter that is a struct of at most 16 bytes (classified into
  registers by its members) makes a call of a long double function defined elsewhere an IR gap ("call of a function
  returning long double with a small aggregate argument") and a definition get no C-convention entry thunk, so only Path B
  code can call it.
- **Variadic functions** returning long double: Path B can define and call them (result pointer first); a Path B one has no
  C-convention entry. One defined elsewhere (`g_sum(3, a, b, c)`, `tests/long-double-abi`) is called through
  `(x87-thunk callv "F" INTS STACK SSE)`, which defines `__nfcxx_x87cv_F_I<INTS>S<STACK>V<SSE>(args..., dst)`: the "..."
  arguments differ per call, so the thunk is made for the call's whole argument list (the same classification as the
  other call thunks, `callvc` for `_Complex`), copies the stack arguments, sets `%al` to SSE, the number of vector
  registers the arguments use, which a variadic callee reads, calls F and stores `st(0)`. The QBE call of the thunk is not
  marked variadic. Taking and passing long doubles through `...` is fully supported (`va_arg` of a long double reads the
  16-aligned overflow area). A call through a pointer to such a function is still refused.
- **Structs of at most 16 bytes that contain a long double.** A struct (or class, nested) of 16 bytes whose only member is a
  long double is class X87: passed in memory, returned in `st(0)`. It is treated exactly as a long double (`ir_is_x87_agg`,
  `ir_x87_mem`): the `(byval (struct "__nfcxx_ld") ...)` argument, the trailing result pointer, the same thunks. gcc agrees on
  the classes (`struct { long double x; }` returned in `st(0)`, its argument at `16(%rbp)`). Refused by name: a union of 16 bytes
  with a long double (its eightbytes merge to MEMORY or INTEGER, which the emitter does not describe:
  `abi-type ... (unsupported "long double")`), and a struct of 16 bytes with a long double plus another member (cannot
  exist: 16 bytes are the long double). `tests/pathb-qbe/cases/x87_struct.cpp`, `multi/abi_x87s` (C and Path B exchange them).
  Larger structs (memory class, `std::complex`, `std::pair<long double, long double>`) work as before.
- **`result_of_overriding_function` thunks** (a covariant or this-adjusting thunk for a virtual function returning long
  double) are IR gaps.
- **`volatile long double`** is read and written with ordinary 16-byte copies (not atomic, not a fence), like the rest of the
  type; the `.v` variants of load/store do not exist for it.
- **`_Float128`/`__float128`** are supported with the same scheme, with gcc's soft-float in libgcc underneath
  (`docs/notes/pathb-float128.md`); `__float80` is `long double` in EDG's layout and works. `__int128` is supported with the
  same scheme (`docs/notes/pathb-int128.md`).
- **Exceptions thrown by libstdc++.so** (`std::stold("zzz")` throws `invalid_argument`) are still not catchable (a documented Path B
  limit independent of the type, `pathb-hosted.md`).
- **`std::format`** builds and runs, with `long double`, `__int128` and `_Float128` arguments
  (`tests/pathb-qbe/cases/float128_format.cpp`; `docs/notes/pathb-float128.md`). It needed the EDG fork's `ignored-routine`
  fix (the `lower_il.c:10294` assertion on `basic_string::_M_construct`), which the pinned `3rd/edg` commit has. The
  `_Float128` formatter calls libstdc++'s `to_chars(char*, char*, _Float128)` in the C ABI (an SSE register), which the
  wrappers of `be/nfcxx_ldrt.c` provide.
- **Speed**: every operation is a call plus 16-byte copies; temporaries are never reused within a function (QBE's frame grows
  by 16 bytes per operation).
- **Targets.** x86-64 only: the emitter checks that `(layout (long_double 16))` is the module's layout and refuses another
  size (`tests/mruby/pathb-edge/r_layout_ld.ir`); Hexagon's 8-byte `long double` and 32-bit layouts are not Path B targets.

## 8. Linux aarch64

On Linux aarch64 `long double` is IEEE binary128 (`__LDBL_MANT_DIG__` 113, 16 bytes, little endian), and the C convention is
AAPCS64, not the System V one of sections 3 and 7. This section describes the AArch64 path. **It is opt-in**:
`NFCXX_LONG_DOUBLE_ABI=aarch64` turns it on, and without it a program that needs the C convention is refused by name
(`(unsupported long double calling convention on aarch64 ...)` in the IR, or the existing x86 form refusal) and the driver
builds it with gcc, as before. The reason is in 8.6: EDG's long double model is the x86 one, so the opt-in path is not
gcc-exact yet, and the default must not trade a fallback for silent differences.

### 8.1 What is always on (no opt-in)

- **The representation.** The layout is the target's (16 bytes, binary128 bits in memory). The helpers of `be/nfcxx_ldrt.c`
  already use the full long double on this host (`NFCXX_LD_BYTES` 16), so arithmetic, comparisons and conversions are
  gcc's.
- **Constants.** EDG hands over a long double constant in its 80-bit x87 form (sign and exponent, a 64-bit significand with
  the explicit integer bit). `ir_x87_bytes` converts it to binary128 on this target: the same sign and exponent, the integer
  bit dropped, the 63-bit fraction shifted up by 49. Before this, the 80-bit bytes were stored as if they were binary128,
  so `long double a[3] = {1.5L, ...}` read back as garbage on Path B (a silent wrong result for every program with a
  long double constant, with or without a call).

### 8.2 The classes

A parameter or result is described by one class letter in the **C view** (AAPCS64): `i` integer, pointer, reference or an
aggregate of more than 16 bytes (its address, the C caller copies it); `d` double; `f` float; `L` long double or a struct
whose only member is one (one SIMD&FP quad, or 16 bytes of stack, 16-aligned); `C` `_Complex long double` (a homogeneous
pair of quads: `q(n)`, `q(n+1)`; gcc passes `struct {long double; long double;}` the same way); `T` `__int128` (an even
register pair); `S` an integer aggregate of 1 to 8 bytes and `U` one of 9 to 16 bytes, alignment at most 8 (one or two general
registers, no even rule). Floating aggregates of at most 16 bytes (HFA-like), `_Float128`, and aggregates of alignment above
8 are not described: a signature with one is refused.

The **internal view** is what Path B passes to QBE on arm64, and it differs for the memory-class types: QBE passes a
`(byval (struct "__nfcxx_ld"))` by address (`isdark` is the memory class, `typclass` in `3rd/qbe/arm64/abi.c`), so `L` and
`C` are a pointer to a copy in one general register (or an 8-byte stack slot), written `P`. `T` and the small integer
aggregates are general-register pairs as in the C view, but with QBE's rules: a pair starts at an even register only when
its alignment is 16, and when the registers run out the whole object goes to the stack with `NGRN` set to 8. The result
`L`/`C` is written through a trailing pointer, as on x86 (section 3); the other results are not moved (see 8.4).

### 8.3 The thunks

`scripts/pathb-a64-thunks.rb` generates them from the class strings. Every thunk saves x0 to x7 and q0 to q7 in its frame
first, so each move reads only memory: the sources and destinations can overlap in registers without a hazard. Scratch
registers are x9 (a pointer to a copy), x10/x11 (copies), x12/x13 (large offsets), and x16 (the callee of an indirect call).
x8 and the result registers are not touched, so an indirect result (x8) and an integer, double or aggregate result (x0, x1,
d0, v0) pass through unchanged.

| form (IR) | symbol | what it does |
| --- | --- | --- |
| `(x87-thunk entry "F" LINK "CLASSES" R)` | `F` | C calls F: moves the C view to the internal view, calls `__nfcxx_ldr_F`, returns q0 (and q1) for `R` = `L`, `C` |
| `(x87-thunk call "F" "CLASSES" R)` | `__nfcxx_x87c_F` | Path B calls F: internal view in, C view out, stores q0/q1 at the trailing pointer |
| `(x87-thunk callv "F" "CLASSES" R)` | `__nfcxx_x87cv_F_A<CLASSES>R<R>` | one variadic call shape: the arguments of that call (AAPCS64 on Linux gives variadic arguments the named registers) |
| `(x87-thunk icall "A<CLASSES>R<R>" "CLASSES" R)` | `__nfcxx_x87i_A<CLASSES>R<R>` | a call through a C function pointer: the callee is the register after the parameters and the result pointer, in x16 for the `blr` |

A routine with an `L` or `C` parameter or result is **thunked**: `ir_a64_rout` (be/nfcxx_ir.c) is true for it, its
definition is `__nfcxx_ldr_F` with the trailing pointer for an `L`/`C` result, its C symbol is the entry thunk, and a call
from Path B goes through `__nfcxx_x87c_F` (or `__nfcxx_x87i_` through a pointer, or the `callv` of its shape). A routine
without one keeps its own name and convention (its ordinary calls are already AAPCS64 with QBE's internal view for the
scalars, aggregates and results it has).

### 8.4 Results and variadic calls

- A result other than `L`/`C` is left where the callee put it: the thunks do not touch the result registers, so a
  `to_chars_result` of two words (x0, x1) or an aggregate through x8 works without a class for it.
- A variadic callee defined elsewhere with a `long double` argument or result (`printf("%Lf", x)`) is called through its
  `callv` thunk, which carries the classes of that call's arguments (`ir_a64_vthunk`).
- A variadic function **defined here** has no C-convention entry on this target, so a call of it that passes or returns a
  `long double` through `...` is refused by name (`call of a variadic function defined here with a long double argument`,
  or `... that returns long double`). The x86 path has no such refusal: its variadic results go through a leading pointer.

### 8.5 The pruner and the IR optimizer

An x87 thunk names the function it reaches (`F`, `__nfcxx_ldr_F`, `__nfcxx_x87c_F`, `__nfcxx_x87cv_F_A...`), and once the
calls to a small function are inlined nothing else names it. `prune_pass` (`scripts/pathb-ir-opt.rb`) therefore follows
these names, so the function a thunk calls survives. This is not AArch64-specific: on x86 it changes only a module that
would otherwise link with an undefined symbol.

### 8.6 Why it is opt-in: EDG's long double model

EDG is configured with the x86 target model (`linux-gcc-release` for the `nfcxx-pathb` build), so its predefined
long double macros (`__LDBL_MANT_DIG__` etc.) are the x86 values, and its constant folding keeps long double values with a
64-bit significand. Measured on aarch64 (the same program through Path B and through gcc):

- `0.1L` prints `0x1.999999999999999ap-4` through Path B and `0x1.999999999999999999999999999ap-4` through gcc;
- `std::numeric_limits<long double>::epsilon()` is `1.0842021724855044340e-19` (the x87 value; the aarch64 one is
  `2^-112`), so `tests/pathb-qbe/cases/longdouble_cmath.cpp` passes its EXPECT on Path B and fails 2 checks on gcc;
- `longdouble_ops`, `longdouble_mem` and `longdouble_random` differ from gcc in the low bits of their literals.

Runtime arithmetic on values that are exact (`one / 3.0L` with `3.0L` exact) matches gcc bit for bit. The fix is in EDG's
target model (`3rd/edg`, not changed here): the binary128 macros and a binary128 constant folder for `linux-aarch64`.
Until then the opt-in is for checking the convention, not for claiming gcc-exact output.

### 8.7 Verified on Linux aarch64 (Ubuntu 24.04 in an Apple `container` VM)

Each result was produced by the driver or the test binary in the VM with the opt-in set (`NFCXX_LONG_DOUBLE_ABI=aarch64`), with Path B forced (`NFCXX_PATH=b`, which makes a
Path B failure an error instead of a gcc fallback) and the C side compiled by gcc (`NFCXX_PATHB_C=gcc`):

- `tests/pathb-qbe/multi/abi_ld` (`a.cpp` by Path B, `c.c` by gcc, both directions: long double with double, float and
  integer arguments, long double arguments past the six integer registers, `_Complex long double` arguments and results,
  and `std::complex<long double>` `*` through EDG's runtime): exit 0, 0 failed checks, with
  `NFCXX_LONG_DOUBLE_ABI=aarch64`. Without it: refused by name, gcc builds it.
- a minimal Path B/gcc pair with `long double`, `double`, `float`, `int` and pointer arguments and results, a `_Complex`
  argument and result, and `printf` of a long double: the values reach gcc's callee and come back unchanged.
- `tests/pathb-qbe/cases/x87_struct.cpp`: output identical to the gcc backend.
- `tests/pathb-qbe/cases/longdouble_cmath.cpp`: builds and runs (its values differ from gcc, see 8.6).
- `tests/pathb-qbe/cases/longdouble_call.cpp`: refused by name (a variadic function defined here returns `long double`),
  so the driver builds it with gcc.
- `tests/pathb-qbe/cases/longdouble_io.cpp`: refused by name with the opt-in (a variadic function defined here, the
  `__to_xstring` instance, is called with a `long double` through `...`), and by the gate without it. Its `_Float128`
  builtins (`nanf128`, `huge_valf128`) are refused on every target by the existing `_Float128` gap, not by this change.
- `tests/pathb-qbe/cases/longdouble_complex.cpp`: builds and runs (its EXPECT is checked; the gcc backend cannot build it).

The QBE translation-validation harness `tests/pathb-qbe/run.sh` (`scripts/pathb-qbe-emit.rb`, the mruby emitter) does not
know the AArch64 forms and refuses them (`expected an integer`); it is not used by the driver's SSA route.

### 8.8 Not done

- EDG's binary128 model (8.6): the largest remaining difference.
- Variadic functions defined here with a long double return or a named long double parameter: refused at their calls.
  A C caller of such a function is not checked, since the definition is not refused by itself.
- Floating aggregates of at most 16 bytes, `_Float128` parameters and results, aggregates of alignment above 8 in a
  thunked signature: refused by name.
- The `tests/pathb-qbe/run.sh` route (the mruby emitter) and the WebAssembly and CIL emitters: they do not read the AArch64
  forms.
