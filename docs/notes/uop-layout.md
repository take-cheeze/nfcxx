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

- **A cost model.** The instruction counts are written in the target description (`Avx2F32`) and in `gemm_rowsum`.
  The FMA term cancels in the comparison, so the decision depends only on the repair and horizontal-sum counts. The
  timings below test its prediction on one host; they do not confirm it at small K.
- **Code generation only for the GEMM pair.** `lib/uop/nfcuop_layout_avx2.*` emits the two GEMM variants with the
  row-sum epilogue as AVX2 C (`emit_gemm_rowsum_c`). The solver does not drive it yet: the caller picks the variant.
  The C renderer (`nfcuop_cgen`) is unchanged and still writes plain loops.
- **Two dimensions, one target, one op pattern.** No 3-D or batched tensors, no AVX-512 (16 lanes), no Hexagon or
  GPU, no tensor-core fragments, and no ILP. The paper's global solver (SCIP over repair graphs) is not needed for a
  graph this small; it is the next step once there is more than one op with a free layout choice.
- **The input layout is fixed** (A and B are row-major). Letting the solver also choose the layout of the inputs at a
  cost is a small change to the model but is not done.

## The AVX2 emitter

`emit_gemm_rowsum_c(GemmVariant, M, N, K)` returns C for `nfc_gemm_rowsum(A, B, C, R, At)`:

- `VecN` (needs `N % 8 == 0`): lanes on N, A broadcast, the row sum is one horizontal sum per row.
- `VecM` (needs `M % 8 == 0`): the kernel first transposes A into `At` (the repair the model charges), lanes on M, C
  written column-major, the row sum added vertically.

Its test (`tests/uop/test_layout_avx2.cpp`) compiles each kernel with `cc -O2 -mavx2 -mfma`, loads it with `dlopen` and
compares C and R with a reference. The inputs are small integers, so the comparison is exact. It is not compared
against the interpreter's `nfcuop` results, which use a different summation order. It also runs under
`UOP_HOST=1` only so far: the nfcxx back ends have not run it.

## Timing against the model (not a test)

`M = N = 256`, `float`, one host with 4 shared cores, best of 7 timings of 20 calls each; the emitted kernels include
the transpose for `VecM`. Two runs of the same benchmark (the second is shown):

| K | vec-n (us) | vec-m (us) | vec-m / vec-n |
| --- | --- | --- | --- |
| 4 | 14.8 | 23.3 | 1.57 |
| 8 | 45.2 | 24.5 | 0.54 |
| 12 | 46.6 | 39.9 | 0.86 |
| 16 | 56.3 | 54.4 | 0.97 |
| 20 | 58.2 | 67.5 | 1.16 |
| 32 | 104.3 | 119.2 | 1.14 |
| 64 | 326.9 | 457.1 | 1.40 |
| 128 | 899.4 | 1444.6 | 1.61 |
| 256 | 1947.8 | 2981.4 | 1.53 |

What this says about the model:

- **K of 32 and up:** vec-n is faster by 1.14 to 1.61 times, in both runs. The model also says vec-n wins above K = 16,
  so the direction matches.
- **Below K = 16:** the runs disagree (K = 8 is 0.54 in the second run and 1.07 in the first), and at K = 4 vec-n
  is faster in both. The model predicts vec-m wins below K = 16. That is not reproduced, so the model is wrong about
  small K here, or the noise on this host is too large to tell. I have not separated those.
- **Why the model is off at small K (a guess, not measured):** it prices the transpose at 3/8 instruction per element,
  an idealized 8x8 SIMD transpose. The emitted transpose is a scalar loop the compiler does not vectorize, and the
  per-(n) loops of `VecM` have short inner loops at small K. Neither is in the model.

## Next steps on this target

1. Repeat the timing on a quieter machine or with more repetitions to settle small K, and check how much of the gap is
   the transpose: time `VecM` with the transpose removed (a pre-transposed A) against `VecN`.
2. Make the transpose a SIMD 8x8 kernel, so the repair costs what the model says, and see whether the small-K crossover
   then appears.
3. Let the solver choose the variant and drive the emitter, so the chosen layout is what runs.
4. AVX-512 as a second target description (16 lanes, `vpermt2ps`-based transposes), to see whether the model's shape holds.

## Tests

`tests/uop/test_layout.cpp` (the model) and `tests/uop/test_layout_avx2.cpp` (the emitter), both run by
`tests/uop/run.sh` (`UOP_ONLY="test_layout test_layout_avx2"`). Neither needs an nfcxx build; the emitter test needs a C
compiler with AVX2 and FMA (it prints SKIP on a CPU without them).
