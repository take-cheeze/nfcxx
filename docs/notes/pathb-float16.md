# Path B: _Float16 (x86-64 Linux)

QBE has no half type, and until now the SSA route refused any function that named `std::float16_t` (`type std::float16_t`), so
a unit with a `_Float16` fell back to the gcc backend (or, with `--backend=pathb`, failed). This note describes the support. It
is done the way gcc does it on x86-64 without AVX512-FP16: the storage is IEEE binary16, every operation is computed in
`float` and rounded back to half, so results match gcc's `-O0` code operation by operation.

The IR is unchanged: a `_Float16` is the floating type `std::float16_t` (`ir_is_float` holds) and the operations are the usual
`fadd fsub fmul fdiv fneg lt.f le.f eq ne fconv i2f u2f cf2i`. The lowering is in the QBE emitter only
(`scripts/pathb-ssa-qbe.rb`, the `Qbe::F16` code and the `f16_*` methods of `Fn`).

## Representation

A value is its binary16 pattern, zero-extended, in a QBE `w` register (class `w`, loads `loaduh`, stores `storeh`, 2 bytes in
memory). A constant is its pattern (`Qbe.half_bits`: the nearest half to the printed decimal, an infinity or the quiet NaN).

## Operations: helper calls

Every operation is a call of a helper of `be/nfcxx_ldrt.c` (`libnfcxxld.a`, which the driver links already for long double; the
archive only pulls in the helpers a program calls). They are the helpers the qbe backend's C front end (cproc) uses, checked
against gcc by `tests/c/float16_ops.c`:

| IR | helper |
| --- | --- |
| `fadd fsub fmul fdiv` | `__nfcxx_f16_add sub mul div` (to float, compute, round once to half) |
| `eq ne lt.f le.f` (and `>`, `>=` by swapping) | `__nfcxx_f16_eq ne lt le` (false on NaN, except `!=`) |
| `fneg` | `xor 0x8000` on the pattern (inline) |
| integer (up to 64 bits) to half | `from_s64`, `from_u64` (one rounding of the exact value) |
| `float`, `double` to half | `from_f64` (a float is widened first, exact) |
| half to `double`, `float` | `to_f64` (and `truncd` for float: both exact) |
| half to an integer | `to_f64`, then the checked double conversion (`cf2i`: NaN and out of range abort, as for `double`) |
| `long double`, `__float128`, `__int128` | be/nfcxx_ir.c: through `double` where that is exact (`__int128` too: a value past double's range is past half's), and `__nfcxx_ld_to_f16`, `__nfcxx_f128_to_f16` from the 16-byte objects, rounded once from the exact value |

Rounding is to nearest, ties to even, including subnormals, infinities and NaN (a NaN stays a NaN; its payload is not kept,
and `tests/c/float16_ops.c` does not check it either).

## ABI (SysV x86-64: class SSE)

A `_Float16` argument or result is the low 16 bits of an XMM register. In the emitter the pattern crosses a call, a parameter
or a return as a QBE `s` value by `cast` (`movd`), and what is received is masked to 16 bits (the upper bits of the register are
whatever the other side left; `tests/c/float16_abi_gcc.c` has a gcc function that leaves garbage there). So a Path B function
and a gcc function call each other with `_Float16` arguments, results and the stack arguments past the eighth XMM register.
Between two Path B functions it is the same convention. Variadic arguments are not a case: C promotes them to `double`.

## What is not supported (refused, never wrong)

- A struct with a `_Float16` member passed or returned by value: its abi-type is `unsupported` ("float of this size"), as before
  (a function using one is not emitted; the driver falls back to gcc).
- `va_arg` of `_Float16`, volatile `_Float16` objects, `__builtin_fpclassify` and `__builtin_signbit` of one (a named gap).
- A negative literal that underflows to zero (`_Float16 h = -1e-30;`): the front end folds it to `+0.0` (EDG's
  `conv_host_fp_to_float16` reports the underflow and leaves the value zeroed), where gcc has `-0.0`.
  `tests/c/float16_fold_negzero.c` is the XFAIL for it. A run-time conversion is right.
- The CUDA and SYCL half types are other types and are untouched.

## Tests

`tests/c/float16_ops.c`, `float16_wide.c`, `float16_abi_gcc.c` pass under Path B (their XFAIL-pathb markers are gone).
`tests/c/float16_exhaustive.c` (with `float16_exh_peer.c`, built by gcc): all 65536 patterns to and from `float`, `double` and
`long double` (the value, one unit either side and the midpoint with the next half value), every integer in [-70000, 70000]
and sampled 64-bit ones, truncation to `long long` of every finite value, `+ - * /` on every pattern against 24 others and on
two million random pairs, the comparisons, `-x`, `++`, `--`, truth; each against gcc's own result.
