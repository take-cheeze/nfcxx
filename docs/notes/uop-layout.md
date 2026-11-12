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

`emit_gemm_rowsum_c(GemmVariant, M, N, K, simd_transpose = true)` returns C for `nfc_gemm_rowsum(A, B, C, R, At)`:

- `VecN` (needs `N % 8 == 0`): lanes on N, A broadcast, the row sum is one horizontal sum per row.
- `VecM` (needs `M % 8 == 0`): the kernel first transposes A into `At` (the repair the model charges), lanes on M, C
  written column-major, the row sum added vertically. The transpose is an 8x8 block kernel (8 unpacks, 8 shuffles,
  8 permutes per 64 elements, the model's 24 instructions) for the 8-aligned part of K, and a scalar tail for the rest.
  `simd_transpose = false` gives the scalar loop, kept so the two can be timed against each other.

Its test (`tests/uop/test_layout_avx2.cpp`) compiles each kernel with `cc -O2 -mavx2 -mfma`, loads it with `dlopen` and
compares C and R with a reference. The inputs are small integers, so the comparison is exact. The VecM shapes run with
both transposes, and K values that are not multiples of 8 cover the scalar tail. It is not compared
against the interpreter's `nfcuop` results, which use a different summation order. It also runs under
`UOP_HOST=1` only so far: the nfcxx back ends have not run it.

## Timing against the model (not a test)

`M = N = 256`, `float`, one host with 4 shared cores, best of 15 timings of 50 calls each. Two runs of the same
benchmark; the second is shown, the first agrees except where noted. `vec-m-simd` and `vec-m-scalar` differ only in the
transpose of A.

| K | vec-n (us) | vec-m-scalar (us) | vec-m-simd (us) | vec-m-simd / vec-n |
| --- | --- | --- | --- | --- |
| 4 | 14.6 | 21.3 | 21.9 | 1.50 |
| 8 | 25.4 | 26.1 | 25.7 | 1.01 |
| 12 | 49.2 | 35.9 | 34.7 | 0.71 |
| 16 | 57.7 | 51.5 | 57.2 | 0.99 |
| 24 | 65.0 | 75.6 | 117.7 | 1.81 (first run: 1.12) |
| 32 | 91.0 | 111.8 | 104.5 | 1.15 (first run: 1.08) |
| 64 | 269.9 | 384.5 | 336.8 | 1.25 |
| 128 | 848.7 | 1361.9 | 1290.4 | 1.52 |
| 256 | 1832.5 | 2757.5 | 2633.8 | 1.44 |

What this says about the model:

- **K of 32 and up:** vec-n is faster, by 1.08 to 1.52 times in the runs. The model says vec-n wins above K = 16.
- **K = 12:** vec-m is faster in both runs (0.67 to 0.73 times vec-n). The model says vec-m wins below K = 16.
- **K = 8 and 16:** the two are within a few percent of each other, which is consistent with the model's tie at 16.
- **K = 4:** vec-n is faster by 1.5 times in both runs. The model says vec-m wins here, so the model is wrong at K = 4.
  The SIMD and scalar transposes take the same time at K = 4, so the transpose is not the cause (this disproves my
  earlier guess). The likely cause is that vec-m reads B one column at a time (`B[k*N + n]`, stride N) while vec-n reads
  it in contiguous vectors. That is an untested hypothesis; the model does not price it.
- **The 24 and 32 rows are noisy:** the first run has 1.12 and 1.08 at K = 24 and 32, the second 1.81 and 1.15.

The SIMD transpose matters little here: the transpose costs MK work against MNK of GEMM, and with N = 256 that is a
small share. It matters most in the scalar-versus-SIMD rows at K = 32, where the scalar loop was 2 times vec-n.

## Next steps on this target

1. Test the B-access hypothesis for the small-K gap: pack B into column blocks before the vec-m loop (or time vec-m
   with a transposed B), and see whether K = 4 moves toward vec-n.
2. Repeat the timing with more hosts or repetitions before drawing a crossover from it; the noise at K = 24 and 32 is
   about as large as the differences.
3. Let the solver choose the variant and drive the emitter, so the chosen layout is what runs.
4. AVX-512 as a second target description (16 lanes, `vpermt2ps`-based transposes), to see whether the model's shape holds.

## Tests

`tests/uop/test_layout.cpp` (the model) and `tests/uop/test_layout_avx2.cpp` (the emitter), both run by
`tests/uop/run.sh` (`UOP_ONLY="test_layout test_layout_avx2"`). Neither needs an nfcxx build; the emitter test needs a C
compiler with AVX2 and FMA (it prints SKIP on a CPU without them).
