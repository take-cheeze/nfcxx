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

- **Function pointers to long double functions use the internal convention.** `&F` is `__nfcxx_ldr_F` (or the call thunk for
  a function defined elsewhere), so a pointer that escapes to code Path B did not compile and is called there with the C
  convention gets the wrong result. Callbacks that return `int` or take a `long double` argument are fine (`qsort`'s
  comparator, tested). Path B code can call a pointer obtained from a Path B function only.
- **Signatures the thunks cannot describe.** The thunks know integers, pointers, float, double, long double and structs
  larger than 16 bytes as parameters (`ir_x87_param`). A parameter that is a struct of at most 16 bytes (classified into
  registers by its members) makes a call of a long double function defined elsewhere an IR gap ("call of a function
  returning long double with a small aggregate argument") and a definition get no C-convention entry thunk, so only Path B
  code can call it.
- **Variadic functions** returning long double: Path B can define and call them (result pointer first); one defined elsewhere
  cannot be called (`call of a variadic function returning long double defined elsewhere`) and a Path B one has no
  C-convention entry. Taking and passing long doubles through `...` is fully supported.
- **Structs of at most 16 bytes that contain a long double** (`struct { long double x; }`) as a parameter or result: the ABI
  class is X87 (result in `st(0)`), which the emitter does not describe; `abi-type ... (unsupported "long double")` refuses.
  Larger structs (memory class, `std::complex`, `std::pair<long double, long double>`) work.
- **`result_of_overriding_function` thunks** (a covariant or this-adjusting thunk for a virtual function returning long
  double) are IR gaps.
- **`volatile long double`** is read and written with ordinary 16-byte copies (not atomic, not a fence), like the rest of the
  type; the `.v` variants of load/store do not exist for it.
- **`_Float128`/`__float128`** stay refused; `__float80` is `long double` in EDG's layout and works. `__int128` is supported
  with the same scheme (`docs/notes/pathb-int128.md`).
- **Exceptions thrown by libstdc++.so** (`std::stold("zzz")` throws `invalid_argument`) are still not catchable (a documented Path B
  limit independent of the type, `pathb-hosted.md`).
- **`std::format`** is still blocked, but no longer by `long double` or `__int128` (`docs/notes/pathb-int128.md`). With the
  EDG fork's `ignored-routine` fix (the `lower_il.c:10294` assertion on `basic_string::_M_construct`; it is not in the pinned
  `3rd/edg` commit) the front end gets through, and `std::format("{}", 1.5L)` stops at `refused: type std::float128_t`: the
  formatter instantiates its visitor for `_Float128` whatever the arguments are. `_Float128` is the remaining piece (a
  software binary128 in libgcc, and an SSE class in the C ABI that the 16-byte scheme does not give). `std::to_chars(long
  double)` and the `std::formatter<long double>` entry points in libstdc++.so take the argument in memory like
  `_M_insert<long double>`, so the long double side needs nothing more once that is done.
- **Speed**: every operation is a call plus 16-byte copies; temporaries are never reused within a function (QBE's frame grows
  by 16 bytes per operation).
- **Targets.** x86-64 only: the emitter checks that `(layout (long_double 16))` is the module's layout and refuses another
  size (`tests/mruby/pathb-edge/r_layout_ld.ir`); Hexagon's 8-byte `long double` and 32-bit layouts are not Path B targets.
