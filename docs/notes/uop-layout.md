# nfcuop layout: instruction-visible layout on the AVX2 target (`lib/uop/nfcuop_layout.*`)

Started from the layout paper (arXiv 2611.13741, Arknife): a tensor's layout is a constraint that instructions impose,
and a global solver picks layouts that minimize repairs. This is the first slice, on the x86 AVX2 f32 target only.

## What it models

- **Layout** of a 2-D f32 tensor: `Axis::Row` or `Axis::Col`, the logical axis that the 8 lanes of a ymm register hold.
  Row-major storage has its lanes on `Col`.
- **Variants** of an op: each declares the lane axis each input must be in (absent = any, such as a broadcast operand),
  the lane axis its output comes out in, and its own instruction count.
- **Repair**: an input in the wrong lane axis for its consumer costs an 8x8 transpose, 24 shuffles per 64 elements
  (`3/8` instructions per element).
- **Solver** (`solve`): brute force over the product of the variant choices, minimizing variant plus repair instructions.
  Ties go to the first minimum in enumeration order (op 0's index varies fastest).

The problem solved here is `C = A*B` followed by a row sum of C (`gemm_rowsum`, M, N, K), with A and B arriving row-major.

| Variant | Requires | Produces | Instructions |
| --- | --- | --- | --- |
| GEMM `avx2-vec-n` (lanes on N) | B: Col (A broadcast) | C: Col | M*N*K/8 |
| GEMM `avx2-vec-m` (lanes on M) | A: Row (B broadcast) | C: Row | M*N*K/8 |
| row sum `reduce-vertical` (lanes on M) | C: Row | none | M*N/8 |
| row sum `reduce-horizontal` (lanes on N) | C: Col | none | M*N/8 + 6*M |

The FMA count is the same for both GEMM variants (one ymm FMA is 8 multiply-adds). A repair on A costs `M*K*3/8`.

## The crossover

Comparing the two combinations that differ, the N-vectorized GEMM costs an extra `6*M` (horizontal sums) and the
M-vectorized one costs an extra `3*M*K/8` (transposing A). The M-vectorized kernel wins when `K < 16` and the
N-vectorized one wins when `K > 16`; at `K = 16` they tie. `tests/uop/test_layout.cpp` checks the solver against these
hand-computed totals at K = 8, 16 and 64, against a cheap-transpose target, and against an infeasible problem.

## What it is not

- **A cost model, not a measurement.** The instruction counts are written in the target description (`Avx2F32`) and in
  `gemm_rowsum`. Nothing here has been timed on hardware. The FMA term cancels in the comparison, so the decision
  depends only on the repair and horizontal-sum counts.
- **No code generation yet.** The solver picks a layout; no AVX2 kernel is emitted. The C renderer (`nfcuop_cgen`)
  writes plain loops, which the C compiler may vectorize, so nothing here changes the generated code.
- **Two dimensions, one target, one op pattern.** No 3-D or batched tensors, no AVX-512 (16 lanes), no Hexagon or
  GPU, no tensor-core fragments, and no ILP. The paper's global solver (SCIP over repair graphs) is not needed for a
  graph this small; it is the next step once there is more than one op with a free layout choice.
- **The input layout is fixed** (A and B are row-major). Letting the solver also choose the layout of the inputs at a
  cost is a small change to the model but is not done.

## Next steps on this target

1. An AVX2 emitter for the N-vectorized and M-vectorized GEMM, checked bit for bit against `nfcuop`'s interpreter (the
   summation order of the vector kernel differs from the interpreter's row-major order, so the check needs a tolerance
   or a matching order).
2. Timing both kernels on the host (`AVX2` and `AVX-512` are present here) to check the crossover against real code.
3. AVX-512 as a second target description (16 lanes, `vpermt2ps`-based transposes), to see whether the model's shape holds.

## Tests

`tests/uop/test_layout.cpp`, run by `tests/uop/run.sh` (`UOP_ONLY=test_layout`). It needs no nfcxx build.
