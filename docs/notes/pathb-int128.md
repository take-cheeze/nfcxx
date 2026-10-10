# Path B: __int128

QBE has no 128-bit integer type either, and until now the Path B emitter refused any IR that named one
(`refused: type __int128_t`). That blocked the 128-bit bit-fields and the libstdc++ code instantiated for `__int128`
(`std::format` is one: its visitor is instantiated for `__int128` whatever the arguments are). This note describes the
support, which follows `docs/notes/pathb-longdouble.md`: a 128-bit integer lives in a 16-byte object, every operation is
a call of a helper that gcc compiled, and the helpers are in the same archive (`libnfcxxld.a`, `be/nfcxx_ldrt.c`).
The difference from `long double` is the calling convention: the System V class of `__int128` is two INTEGER
eightbytes, which QBE passes and returns like a `{ long, long }` struct, so no thunk is needed.

Decision, as before: no approximation. Behaviour is gcc's (section 3), and a construct that is not supported is a named
refusal (section 6).

## 1. Representation

`__int128` and `unsigned __int128` (EDG's integer kinds of size 16, not bool) are `(array 16 unsigned_char)` with
alignment 16 in the IR (`nf_put_unqualified_type` prints the blob in IR mode only, as for `long double`). The value of an
expression of that type is **the address of a 16-byte object**: `ir_is_i128` in `be/nfcxx_ir.c`, `ir_is_obj16` for the
copy-on-read and copy-on-store rules shared with `long double`, `ir_is_memval` true for both. The C ABI shape is a named
struct, `(struct "__nfcxx_i128")`, declared once per module as

```
(abi-type "__nfcxx_i128" 16 16 (leaf 0 l) (leaf 8 l))
```

so `(byval ...)` arguments are passed in two integer registers and `(sret ...)` results come back in rax:rdx, exactly as
gcc passes them. A function returning a 128-bit value uses the aggregate result convention (`(sret ...)`), not the
trailing pointer of `long double`. An aggregate with a 128-bit member classifies it as two `l` leaves, and a 128-bit
bit-field makes each eightbyte its bits touch INTEGER (`ir_abi_collect`).

## 2. Operations

Every operation is `(eval (call void &"__nfcxx_i128_NAME" DST A B))` or `(call RTY &"__nfcxx_i128_NAME" A B)`, with
operands that are addresses (`ir_i128_call`, `ir_i128_ret`).

| IR source | helper |
| --- | --- |
| `+ - * & \| ^`, unary `-`, `~`, `++`/`--`, compound assignments | `add sub mul and or xor neg not` (wrapping) |
| `/`, `%` | `div_s rem_s` (signed), `div_u rem_u` (unsigned) |
| `<< >>` | `shl shr_s shr_u`; the count is a `long` (`count` of a 128-bit count, -1 when it does not fit) |
| `< <= > >= == !=` | `lt_s le_s lt_u le_u eq ne` (`>`, `>=` swap the operands), 0 or 1 |
| condition, `!`, `&&`, `\|\|`, `?:` | `nz` |
| integer to 128-bit | `from_s64`, `from_u64` (narrower types are widened first) |
| float, double, long double to 128-bit | `from_f32_s/u`, `from_f64_s/u`, `from_ld_s/u` (checked, see 3) |
| 128-bit to a narrower integer | `lo64` and the IR's `iconv` |
| 128-bit to float, double, long double | `to_f32_s/u`, `to_f64_s/u`, `to_ld_s/u` |
| 128-bit to bool | `nz` |
| pointer and 128-bit | through `p2i`/`i2p` and the 64-bit helpers |
| subscript, pointer arithmetic, shift count of another type | `count` (converted to `long`) |
| bit-field of 128-bit type | `bfget`, `bfset` (bit-level, reading and writing only the bytes the field covers) |

Constants are two 64-bit stores into a temporary (`ir_i128_lit`), or two `(scalar ...)` items for a static initializer.
EDG prints an integer constant in decimal or in hex (`0x...`) with a `-` for a negative one; `ir_i128_parts` takes both.

## 3. Semantics (gcc's)

- **Wrapping.** `+ - * neg` wrap (two's complement), as gcc does without `-ftrapv`. Overflow is not checked even in
  `NFCXX_IR_OVERFLOW=trap` mode.
- **Division and remainder** call the same functions gcc calls (`__divti3`, `__modti3`, `__udivti3`, `__umodti3`), so
  `INT128_MIN / -1` wraps to `INT128_MIN` and a zero divisor dies the way gcc's program does: SIGFPE for a divisor known
  only at run time (gcc at -O0 and gcc's own libgcc give 136). A literal zero divisor is folded by gcc at -O2 into `ud2`
  (SIGILL), which Path B does not reproduce; that is gcc's optimizer, not its semantics.
- **Shifts** abort when the count is negative or not below 128 (the IR's `cshl`/`cshr` rule for every integer type). gcc
  leaves this undefined; the abort is the Path B choice.
- **Conversions from floating types** truncate toward zero, like gcc, and **abort** on a NaN or a value outside the
  destination type (the `cf2i` rule of the IR for the other integer types). gcc leaves this undefined.
- **Conversions to floating types** are the libgcc ones (`__floattidf`, `__floatuntixf`, ...), rounded as gcc rounds.

## 4. Switch

The IR's `switch` selects on a scalar. A `switch` on a 128-bit value lowers the selector to a `long`: the low word when
the value is the sign extension of it (`from_s64` of the low word compares equal), else a value that no case label has,
which goes to `default`. The labels are collected while the body is lowered (into a buffer written after the selector
is known, `ir_switch_wide`). A label that does not fit a signed 64-bit value is a named refusal
(`(unsupported stmt switch-case-128)`), because a value in `[2^63, 2^64)` would collide with the same bits as a negative
one.

## 5. Bit-fields

A bit-field of 128-bit type (`unsigned __int128 f : 100`) is an lvalue with `bf_unit` 16: its object is the address of the
enclosing object and `bf_boff` the bit offset from it. `bfget` extracts the bits (sign-extended for a signed field) and
`bfset` replaces them, byte by byte, so the bytes outside the field are never touched and nothing is read past the object.
In a static initializer the field is one `(bitfield OFF 1 BOFF WIDTH unsigned_char (const unsigned_char V))` item per byte
it touches (the emitter places each bit at its absolute position; `ir_gi_i128_bits`).

## 6. Limits and named refusals

- **`va_arg` of a 128-bit type** is `(unsupported op va_arg (__int128))`: the emitter refuses it. Passing one through `...`
  works (the callee does not read it); reading it would need the register save area logic of `va_arg`.
- **Case labels** outside the signed 64-bit range (section 4), and their collisions, are refused by name.
- **`_Float128`** (`std::float128_t`) is a separate type and still refused. `std::format` instantiates a visitor for it
  as well as for `__int128`, so **`std::format` still does not build**, with the same refusal and no new cause on the
  128-bit side: with the EDG fork's `ignored-routine` change (the `lower_il.c` assertion on `basic_string::_M_construct`),
  the refusal moves from `type __int128_t` to `type std::float128_t`. The pinned `3rd/edg` commit does not have that
  change, so `std::format` stops in the front end before that. `std::to_chars(char*, char*, __int128)` is not an overload
  in strict `-std=c++NN` mode; `to_chars` of `long double` works (`longdouble_io.cpp`).
- **`std::atomic<__int128>`** works (`tests/pathb-qbe/cases/int128_atomic.cpp`), but the 16-byte `__atomic_*` calls need
  libatomic at link time, which the Path B link has (`-latomic`) and the gcc backend's link line does not; that probe is
  therefore not compared with gcc.
- **Speed.** Every operation is a call plus 16-byte copies (temporaries are not reused within a function), as for
  `long double`.

## 7. Tests

| Test | What it checks |
| --- | --- |
| `tests/pathb-qbe/cases/int128_ops.cpp` | arithmetic, division and remainder (signed and unsigned, negative operands), shifts, comparisons, `++ --`, compound assignments, conversions among integer types, constants, globals, arrays, members, arguments and results, function pointers, virtual calls, bit-fields (runtime and static); printed in hex, compared with gcc byte for byte |
| `tests/pathb-qbe/cases/int128_fp.cpp` | conversions to and from float, double and long double, rounding of large values, mixed comparisons, compound assignments through floating types; the long double bytes are printed |
| `tests/pathb-qbe/cases/int128_misc.cpp` | switch (negative labels, values outside 64 bits, fallthrough, nested switch), exceptions carrying a 128-bit value, variadic calls, `std::function`, `std::sort` of 128-bit values |
| `tests/pathb-qbe/cases/int128_atomic.cpp` | `std::atomic<__int128>` and `<unsigned __int128>` (self-checking, not compared with gcc) |
| `tests/pathb-qbe/multi/abi_i128/` | the C ABI both ways: `__int128` arguments in registers and on the stack, results in rax:rdx, a struct of one 128-bit member, a 48-byte struct in memory; `c.c` built by cc |
| `tests/pathb-qbe/traps/int128_div_zero.cpp` | division by a zero divisor known at run time dies with SIGFPE (136), as gcc's |
| `tests/pathb-qbe/traps/int128_float_range.cpp` | a float out of the 128-bit range aborts |
| `tests/pathb-ir/eval_order_calls.ir` | golden: the lowering of the `__uint128_t` numeric limits and static initializer |
