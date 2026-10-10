# Path B: _Float128 (__float128, std::float128_t)

QBE has no 128-bit float either, and until now the Path B emitter refused any IR that named one (`refused: type
std::float128_t`). That blocked `std::format`: GCC 13's `<format>` instantiates its argument visitor for `_Float128`
whatever the arguments are (`basic_format_arg` stores a `_Float128`, and the formatter calls `to_chars(char*, char*,
_Float128)` of libstdc++.so). This note describes the support. It follows `docs/notes/pathb-longdouble.md` and
`docs/notes/pathb-int128.md`: a 16-byte object in the IR, every operation a call of a helper in `libnfcxxld.a`
(`be/nfcxx_ldrt.c`, built by `scripts/pathb-ldrt`), and the results are gcc's, because the helpers are gcc-compiled C and
gcc lowers `_Float128` arithmetic to libgcc's soft-float routines (`__addtf3`, `__multf3`, `__divtf3`, `__eqtf2`,
`__fixtfdi`, `__fixtfti`, `__floattitf`, `__trunctfxf2`, `__extendxftf2`, `__extendsftf2`, ...), which are linked from
`libgcc.a`. Nothing is written by hand.

Decision, as before: no approximation. A construct that is not supported is a named refusal (section 6), never a wrong
value silently.

## 1. Representation

A `_Float128` (`__float128`, `_Float128`, and `std::float128_t`, which EDG keeps as a separate float kind,
`fk_std_float128`) is `(array 16 unsigned_char)` with alignment 16 in the IR, like `long double` and `__int128`
(`nf_put_unqualified_type` prints it so in IR mode only). The value of an expression of that type is **the address of a
16-byte object** holding the IEEE binary128 bits, little endian, which is the object gcc uses. `ir_is_f128` in
`be/nfcxx_ir.c` recognizes the type, `ir_is_fobj` covers `long double` and `_Float128` together (the shared helper
path), `ir_is_float` is false for both (so no float code path takes them), and `ir_is_memval` is true: reads copy the
object, stores are copies.

Constants come from EDG's own value. Linux's EDG build uses a host `__float128` for float values
(`USE_FLOAT128_FOR_HOST_FP_VALUE=1`, `3rd/edg/src/targ_def.h`), so `float_value.bytes` holds the binary128 bits already and
`ir_x87_bytes` copies all 16 of them (a `long double` takes 10). A constant is two 64-bit stores into a temporary, and a
static initializer two `(scalar ...)` items, as for `long double`.

## 2. Operations

Every operation is a helper call with operands given by address, as for `long double` (`ir_fo_call`, `ir_fo_ret`, with the
prefix `__nfcxx_f128_` instead of `__nfcxx_ld_`):

| IR source | helper |
| --- | --- |
| `+ - * /`, unary `-`, `++`/`--`, compound assignments | `add sub mul div neg` |
| `< <= > >= == !=`, conditions, `!`, `&&`, `\|\|`, `?:` | `lt le gt ge eq ne nz` |
| integer (up to 64 bits) to `_Float128` | `from_s64`, `from_u64` |
| `__int128` to `_Float128` | `__nfcxx_i128_to_f128_s/u` (the 128-bit family) |
| `float`, `double` to `_Float128` | `from_f32`, `from_f64` |
| `long double` to `_Float128` | `from_ld` |
| `_Float128` to `long double` | `to_ld` |
| `_Float128` to `float`, `double` | `to_f32`, `to_f64` |
| `_Float128` to an integer of up to 64 bits | `to_s`, `to_u`: truncate toward zero, **abort on NaN and on a value that does not fit** |
| `_Float128` to `__int128` | `__nfcxx_i128_from_f128_s/u` (the same checked rule, 128-bit bounds) |
| `__builtin_fpclassify`, `isnormal`, `isgreater` ... `isunordered` | `fpclassify isnormal gt ge lt le isunordered` |
| `__builtin_isnan/isinf/isfinite/signbit` | `isnan isinf isfinite signbit` (take the object) |

The checked conversions are the IR's `cf2i` rule (section 3 of `pathb-int128.md`). The bounds are exact in binary128: a
value `x` converts to a signed `B`-bit integer when `x > -2^(B-1) - 1` (or `x >= -2^(B-1)`, which covers the
`__int128` minimum, where `-2^127 - 1` is not representable) and `x < 2^(B-1)`; to an unsigned one when `x > -1` and
`x < 2^B`.

Mixed expressions need nothing more: EDG inserts the conversions. `ir_common_type` prefers `_Float128` when one operand has
it, and the cast path (`ir_x87_conv`) converts between the three floating kinds, integers and `_Float128`
(`ir_conv_num` also checks the object kind before it reuses a value, since `long double`, `_Float128` and `__int128` print
the same IR type).

## 3. Calls inside Path B

A `_Float128` argument is `(byval (struct "__nfcxx_f128") ADDR)`, a memory-class aggregate
(`(abi-type "__nfcxx_f128" 16 16 (memory))`, declared once per module). A `_Float128` result is `(sret ...)`, the hidden
pointer first, as for any memory-class aggregate. Function pointers, virtual functions and templates use the same
convention, since every caller and callee is Path B code. The emitter is unchanged: the IR describes the type with the
existing `abi-type` forms, so `scripts/pathb-qbe-emit.rb` and its Python oracle are byte-identical to before.

Path B's definitions with *external* linkage that take or return a `_Float128` have no C-convention entry (the C-ABI
entry thunk of `long double` is assembly and is not generated for this type). Only Path B code can call them: the limit
of `pathb-longdouble.md`, section 7, for an entry the thunks do not describe. Templates, inline functions and
`std::format`'s instantiations are weak and are called only by Path B code.

## 4. Calls of C functions: wrappers

The C convention passes a `_Float128` in one SSE register (class SSE with SSEUP) and returns it in xmm0. QBE cannot express
that, so a call from Path B of a routine defined elsewhere (libstdc++.so, libm, libc) whose signature has a `_Float128`
goes to a wrapper instead: `__nfcxx_f128w_` + the routine's linkage name (`ir_call`, `ir_f128_wrapped` in
`be/nfcxx_ir.c`). The wrapper is written in C in `be/nfcxx_ldrt.c`, compiled by gcc, and has the same routine inside
with the C prototype (an `__asm__` label names the symbol): the `_Float128` operands are passed by pointer (an ordinary
integer register), and a `_Float128` result is written through a first pointer, which the wrapper also returns in rax: the
hidden pointer of a memory-class aggregate result, as the C convention of a struct gives it and as QBE's call of an
aggregate result reads it (a wrapper that returns void gets whatever rax holds, which is a wrong value, not a crash). Routines with a `_Float128` operand and no wrapper
are a named refusal (`call of ... (_Float128 signature, no wrapper)`), and variadic routines with one are refused too.

The wrappers present:

| symbol | used by |
| --- | --- |
| `_ZSt8to_charsPcS_DF128_`, `..._St12chars_format`, `..._St12chars_formati` | the `std::to_chars(char*, char*, _Float128)` overloads, which `<format>` calls for a `_Float128` argument |
| `fabsf128` | `std::abs(_Float128)` of `<cmath>` (a built-in: the wrapper calls gcc's `__builtin_fabsf128`) |

## 5. Aggregates with a 16-byte float

The System V class of a 16-byte aggregate that holds a `long double` or `_Float128` follows from the merge of its members'
classes, and INTEGER wins over X87 and SSE. `std::format`'s `__format::_Arg_value` is such a union (`long double`,
`_Float128`, `__int128` and pointers): each eightbyte has an integer member, so its class is two INTEGER eightbytes, which
is what Path B passes. The IR marks each 16-byte float with two `m` leaves (`ir_abi_collect`, `tk_float`). The union merge
(`ir_abi_collect`, union branch) gives an eightbyte that holds an `m` and an integer the INTEGER class, and refuses an
eightbyte whose only members are the float (its class would be X87 or SSE, which the thunks and the emitter do not
describe). An `(abi-type)` whose leaves still hold an `m` is refused by name (`(unsupported "long double or _Float128
member")`): that is a bare `long double` or `_Float128` in a 16-byte struct, as before for `long double`.

## 6. Limits and named refusals

- `va_arg(ap, _Float128)` is refused by name: the argument is an SSE register in the C convention. Passing one through
  `...` to Path B code works (the callee reads it as a memory object); passing one through `...` to a C routine is refused
  (a variadic routine with a `_Float128` operand has no wrapper).
- Calls of C routines with a `_Float128` in their signature, other than the ones in section 4, are refused by name. Adding
  one is a wrapper in `be/nfcxx_ldrt.c` and a line in `ir_f128_wrapped`.
- A Path B definition with external linkage that takes or returns `_Float128` is callable from Path B only (section 3).
- An aggregate with a `_Float128` passed by value to a C routine is classed by section 5, which is the System V class
  except in one place: a struct or union whose eightbytes are all SSE in C (for example a union of `_Float128` and
  `double`) is refused, since no eightbyte with an integer member is involved; a union whose integer members reach both
  eightbytes is INTEGER in both, as in C, and one whose integer members reach only one is refused. Keep such aggregates to
  Path B code.
- `_Complex _Float128` and the `_Float128x` kinds are not lowered (an IR gap, refused by name where they are used).
- Speed: each operation is a call plus 16-byte copies, as for `long double`.

## 7. Tests

| Test | What it checks |
| --- | --- |
| `tests/pathb-qbe/cases/float128_ops.cpp` | constants (EDG's binary128 value against gcc's), arithmetic, compound assignments and increments, comparisons with NaN and infinities, classification built-ins, conversions to and from int, `__int128`, float, double, long double, members, arrays, static initializers, arguments and results, a function pointer, a virtual call; every result printed as its 128-bit pattern and compared with gcc byte for byte |
| `tests/pathb-qbe/cases/float128_format.cpp` | `std::format("{} {}", 1.5L, 2)` (the probe of the task), `std::format` of double, long double and `__int128`/`unsigned __int128`, `std::to_chars` and `std::format` of `__float128` through the wrappers, with and without a precision and a `chars_format` |
| `tests/pathb-qbe/cases/format_ld_int.cpp` | `std::format("{} {}", 1.5L, 2)` alone, the probe of the task |
| `tests/pathb-qbe/cases/float128_cmath.cpp` | `std::abs(__float128)` through the `fabsf128` wrapper, and the classification built-ins of a `_Float128` |
| `tests/pathb-qbe/traps/float128_to_int.cpp` | a `_Float128` out of the int range aborts (the `cf2i` rule) |
| `tests/pathb-ir/abi_struct.ir`, `eh_exception_ptr.ir`, `eh_libstdcxx_throw.ir`, `eval_order_calls.ir` | goldens: the `std::numbers` `_Float128` constants now lower to two 64-bit items, `std::abs(_Float128)` calls its wrapper, and the `(abi-type "__nfcxx_f128" ...)` declaration appears |

## 8. Build and link

No new library: the helpers and wrappers are in `be/nfcxx_ldrt.c`, so the `libnfcxxld.a` every Path B link already adds
(`scripts/pathb-ldrt`) has them. The wrappers name `libstdc++.so` symbols, which the link has (`-lstdc++`), and
`fabsf128` is a gcc built-in. The EDG fork needed no change: the pinned `3rd/edg` commit has the `_Float128` front end
(`fk_float128`, `fk_std_float128`, the host `__float128` value) and the `ignored-routine` fix that `std::format` needs.
