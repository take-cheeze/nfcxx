# Path A (qbe): __float128 and long double in EDG's float_pt

Status: scoping note. No lowering is on the branch. This records what float_pt needs, the three options, and a recommendation.

## Reproduce

    cd /home/user/wt-float128
    bash scripts/setup-qbe.sh                       # cproc + qbe in build/
    EDG_SRC=/home/user/edg-compiler EDG_BUILD=$PWD/build/edg EDG_BASE=$PWD/build/edg-base bash scripts/setup-edg.sh
    # float_pt as EDG's CMake builds it (C++ mode, qbe backend):
    NFCXX_BACKEND=qbe EDG_BUILD=$PWD/build/edg EDG_BASE=$PWD/build/edg-base ./nfcxx -c \
      -DUSE_EDG_NAMESPACE=1 -DBACK_END_IS_C_GEN_BE=1 -DCOMPILE_MULTIPLE_TRANSLATION_UNITS=1 \
      -DDO_IL_LOWERING=1 -DLOWER_FIXED_POINT=1 -DLOWER_IFUNC=1 -DNEED_IL_DISPLAY=1 \
      -DRECORD_BACKING_EXPRS_WITH_IL_LOWERING=1 -DUSE_CMAKE_DEFINES \
      -I$PWD/build/edg/src/includes -I/home/user/edg-compiler/src -o float_pt.o float_pt.cpp
    # float_pt.cpp is a symlink to src/float_pt.c (nfcxx treats .c as C).
    # Error: <stdin>:4530:9: declaration has no type specifier  (typedef __float128 ...)

The EDG source used is the local fork `/home/user/edg-compiler` (HEAD 92d32d975). The submodule pin in `3rd/edg` (740fbed) is not in that fork, and fetching it failed on a full disk. Eval-order failures in `tests/run.sh` appear with and without any change here, so they come from this EDG source, not from the qbe chain.

## Constructs in float_pt

Taken from the EDG output after preprocessing (`float_pt.int.c`, the same text qbe-prep sees) and gcc's typed dump of it (`-fdump-tree-original`, where every float128 operation is an explicit `(_Float128)` cast or a typed comparison).

| Construct | Where (line in the prepared C) | Count |
| --- | --- | --- |
| `typedef __float128 a_host_fp_value` (the host FP type, `USE_FLOAT128_FOR_HOST_FP_VALUE=1`) | 4530 | 1 |
| Conversions to float128: from `float`, `double`, `long double`, `_Float16`, `int64`, `uint64` | 1936, 1952, 1968, 1990, 3955, 3977 | 6 |
| Conversions from float128: to `float`, to `double`, to `long double` (round trip) | 1780 and the `(float)`, `(double)` casts in `conv_host_fp_to_*` | 5 |
| Comparisons `== != < > \|\|` on float128 values | 1561, 1572, 1679, 1690, 6713, 6729, 6746, 6754, 7121, 7187, 7194 | ~11 |
| Literals `0.0Q`, `±10000.0Q`, `±9.22e18Q`, `1.84e19Q` | 5665–5720, 6713–6754, 7147 | ~15 lines |
| Assignments, parameters and returns of 16-byte float128 values (`host_fp_value_is_finite(__float128)`, `fp_zero = 0.0Q`) | 5643, 7147 and many call sites | many |
| libm / math functions on float128 | none. `is_finite` inspects the bytes; `__isnan((double))` (6037) is a double call | 0 |

Not float128, but the same blocker: `long double` is also used by float_pt, and cproc cannot compile any `long double` (`qbe.c:206`, "long double is not yet supported", fatal at code generation). Sites: 4942 (prototype), 5718 (double to long double), 5739–5752 (`zero_unused_bits_in_long_double`, which writes the x87 padding bytes, and the round trip), 5818 (a local). EDG reads the stored bytes in x87 80-bit layout, so a replacement type must keep that layout.

Two more blockers, found by compiling past the typedef:

- `__builtin_fabsf` (libstdc++ `std::fabs(float)`, from `<cmath>`, prepared-C line 5479) is not a cproc builtin. The prototype maps it to a helper.
- `(_Float128) float16_temp` (line 1936): `_Float16` is a 2-byte struct in qbe-prep, so this conversion fails too. This is the same float16 case that makes Path B refuse the file.

## Prototype (not committed)

Two changes to `scripts/qbe-prep.rb` move the first error. Nothing else changes.

1. `'__float128' => 'struct __nfcxx_float128'` in `FLOAT_TYPE`. The type becomes the same 16-byte, no-arithmetic struct as `_Float128`.
2. A `HELPER_BUILTINS` entry for `__builtin_fabsf` (clears the sign bit through a union).

Result: the first error moves from `4530:9` (typedef) to `5479` (`__builtin_fabsf`, fixed by change 2) and then to `5666:85`, `cast operand must have scalar type` (`(float)` on the struct). cproc rejects every float128 arithmetic, comparison and cast, so the mapping cannot compile wrongly. `float_pt` still does not compile.

Tests with the prototype: `NFCXX_BACKEND=qbe bash tests/c/run.sh` gives 11 of 11. `NFCXX_BACKEND=qbe bash tests/run.sh` gives 20 ok and the same 14 eval-order failures as the committed `qbe-prep.rb`. Because the second suite does not pass, the prototype is not pushed.

## Options

**(a) Lower float128 (and long double) in qbe-prep.** Each operator and cast would be rewritten to a helper call. qbe-prep runs under mruby and sees text, not types. A correct rewrite needs a C expression parser with typedef, struct-member and return-type tracking, plus correctly rounded decimal-to-binary128 literal conversion, plus x87 handling for `long double` (its layout is part of the observable result). Estimate: 1000 or more lines of Ruby, fragile. Risk: a misjudged operand type becomes a silent wrong value, and literal rounding must match gcc exactly. Not recommended.

**(b) cproc support for two 16-byte float kinds (`long double`, `__float128`).** Each value stays in memory. Every arithmetic operator, comparison, conversion and literal becomes a call to a helper that takes operands by address. This is the design Path B already uses (`docs/notes/pathb-float128.md`, `docs/notes/pathb-longdouble.md`). The runtime can be reused: `be/nfcxx_ldrt.c` (333 lines, gcc-compiled, so gcc's soft-float routines do the arithmetic) would be linked by qbe-cc. Estimate: cproc changes in `type.c`, `eval.c`, `expr.c` and `qbe.c` of about 500 to 800 lines, plus tests, roughly 3 to 5 days. It must be kept as a cproc patch, like the three existing ones in `scripts/`. Risks: cproc folds float constants in C `double`, so folding must be disabled for these kinds. Existing passing files do not use `long double` today (cproc rejects it), so their output should not change, but the patch must be refreshed whenever 3rd/cproc moves.

**(c) Named refusal in qbe-prep.** Detect `__float128`, `long double` and `_Float16` in the expanded C and stop with a message that names the construct and points to this note. About 15 lines. No risk to constant folding or existing tests. float_pt still fails, but the diagnosis is clear.

## Recommendation

Do (c) now, because it is cheap and honest. Treat (b) as the real fix and plan it as its own piece of work, reusing Path B's runtime. Do not do (a). Path B refuses std::float16_t in this file, and the float16 conversion at line 1936 is that construct, so it needs its own decision.

Not checked here: the three ifc_* failures in the probe (`ifc_map_functions_acc`, `ifc_map_functions_val`, `ifc_modules_templ`) may have different causes.
