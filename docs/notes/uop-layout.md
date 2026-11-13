# nfcuop layout: instruction-visible layout on the AVX2 target (`lib/uop/nfcuop_layout.*`)

Started from the layout paper, Arknife (see [References](#references)): a tensor's layout is a constraint that instructions impose,
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

## Storage of the lanes-on-M tensors

A tensor in Row lanes (the lanes on M) can be held in `Storage::Strided` (column by column, so the lanes of one access
are a row length apart) or `Storage::Blocked8` (8-row blocks, each contiguous). The solver enumerates both for each
Row-lane tensor the plan holds: a GEMM output in Row lanes (C in `avx2-vec-m`), or the copy a repair makes in Row lanes
(the transposed A). `Solution::storage` reports the choice, keyed by tensor name, and `Solution::storage_cost` is its
term of `Solution::cost`. Per tensor of `numel` elements:

    storage cost = numel * strided_instr_per_elem    (Strided)
                 = numel * blocked_instr_per_elem    (Blocked8)

with `strided_instr_per_elem = 0.46` and `blocked_instr_per_elem = 0` (`Avx2F32`). The ties go to Strided.

Sources of the constants. The timings are in `docs/notes/uop-layout.md` on branch `claude/sleepy-faraday-n2e9k7`
(commits `f20a2e64`, `f09a38d2`, `d72bf5ba`), and the rounds below name the sections there. All are `M = N = 256`, one host.

- **Strided, `0.46`.** At K = 8 the strided M-vectorized kernel runs at 1.41 times vec-n (round 2, quiet host), about 1.4
  (round 3, the stores ablation) and 1.47 (round 4, -O2). The model's blocked vec-m is 74,496 instructions and vec-n is
  75,264 (0.99). The excess, `(1.40 - 0.99) * 75264 = 30,858`, is spread over the 67,584 elements of A^T and C
  (2,048 and 65,536), giving 0.46. This converts a time ratio into the model's instruction units by assuming the
  instruction count of vec-n tracks its time at this shape, which the model already assumes.
- **Blocked, `0`.** The blocked kernel's time over vec-n is 1.00, 0.98, 0.92, 1.16, 1.00 at K = 8, 16, 24, 32, 64 (round 5,
  -O2; at -O3 it is 0.82, 0.77, 0.92, 1.03, 1.07). The model's blocked vec-m over vec-n is 0.990, 1.000, 1.004, 1.006,
  1.009. The measurements show no excess over the model's count: at -O3 the blocked kernel is faster than the model at
  K = 8 and 16, and at -O2 it is slower only at K = 32 (1.16, against 1.03 at -O3). The blocked own cost is zero.

How the penalty fits the measured strided-over-vec-n ratio (round 4, -O2, vs the model with the constant above):

| K | 8 | 16 | 24 | 32 | 64 |
| --- | --- | --- | --- | --- | --- |
| measured | 1.47 | 0.89 | 1.12 | 1.16 | 1.46 |
| model | 1.40 | 1.23 | 1.16 | 1.13 | 1.08 |

It matches at K = 8, 24 and 32. It misses K = 16 (the measured strided kernel is faster than vec-n, the note's K = 16
is unexplained) and K = 64, where the strided kernel is 1.46 times vec-n at both flags. A per-element term cannot give
K = 64 without a much larger constant, which would then break K = 8, so the constant is kept at the K = 8 value rather
than fit to the spread of the other points.

What follows. With a positive strided penalty and free blocked storage, the solver chooses Blocked8 for every Row-lane
tensor. Strided is kept only when the penalty is zero or the blocked cost is higher, and the `storage_cost` tests in
`tests/uop/test_layout.cpp` cover both. At M = N = 256 the choice is vec-m with Blocked8 at K = 8 and 16 (16 is still a
tie, broken to vec-m) and vec-n at K = 24 and 64. The measured blocked kernel is 0.92 of vec-n at K = 24, so the model's
crossover at K = 24 (vec-n by 0.4%) is inside the spread of the measurements; the model puts the crossover at K = 16 as before.

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

## Packed-B test (second round, quiet host)

Hypothesis from the first round: the M-vectorized kernel reads B column-wise (`B[k*N + n]`, stride N), and that cost
explains the small-K gap. Test: the same kernel with B packed once into `Bt[n*K + k]`, so the broadcast of B reads
contiguous memory. Packing is timed separately and is not in the kernel timing. The packed kernel gives the same bits as
the strided one (same summation order), checked in the driver. `M = N = 256`, best of 15 timings of 50 calls each;
two runs, the second agrees with the first within a few percent. Load average was under 1 during the runs.

| K | vec-n (us) | vec-m (us) | vec-m packed B (us) | pack (us) | vec-m / vec-n | packed / vec-n |
| --- | --- | --- | --- | --- | --- | --- |
| 4 | 28.6 | 29.9 | 30.2 | 2.1 | 1.04 | 1.05 |
| 8 | 40.0 | 56.6 | 59.1 | 2.1 | 1.41 | 1.48 |
| 12 | 61.9 | 57.4 | 58.1 | 2.7 | 0.93 | 0.94 |
| 16 | 78.6 | 69.3 | 68.0 | 5.0 | 0.88 | 0.87 |
| 24 | 92.9 | 104.1 | 121.5 | 3.7 | 1.12 | 1.31 |
| 32 | 134.7 | 152.9 | 141.4 | 4.5 | 1.14 | 1.05 |
| 64 | 434.9 | 513.2 | 372.9 | 8.2 | 1.18 | 0.86 |
| 128 | 1279.1 | 1781.0 | 1374.3 | 39.4 | 1.39 | 1.07 |

What this says:

- **Packing B does not change the time at any K.** The column-wise reads of B are not the cause, so the hypothesis is
  rejected.
- **Correction to the first round.** The first round reported vec-n about 1.5 times faster at K = 4, and this round finds
  parity (1.04). The earlier small-K numbers came from a busier host and are not reliable; the claim above is withdrawn.
- **What holds on a quiet host:** vec-m is slower at K = 8 (about 1.4 times) and at K = 24 to 32 (about 1.1 to 1.14),
  and faster at K = 12 to 16 (about 0.9). vec-n is faster at K = 64 and up (1.2 to 1.4 times, vec-m / vec-n).
- **Against the model:** the model predicts vec-m wins below K = 16 and vec-n above it. This round supports the
  prediction only at K = 12 to 16, and it contradicts it at K = 8. Above K = 24 it agrees.

The timing driver and the generator used for this round are not in the repository. They wrap the emitter's output
with the entry point renamed to `kernel` and a sixth argument `Bt`, and the strided kernel's `B[k * N + n]` broadcast
replaced by `Bt[n * K + k]` for the packed variant.

## Where the M-vectorized gap comes from (third round, quiet host)

Three ablations of the M-vectorized kernel, all hand-written scratch kernels (not the emitter), each timed against the
emitter's kernels, two runs per set, `M = N = 256`:

- **Stores removed** (`nost`): the per-column stores of C are dropped; the row sum still uses the accumulator.
- **Contiguous stores** (`stc`): the same stores, but each 8-row block of C lands contiguously instead of 1 KB apart.
- **Transpose removed** (`noT`): the A transpose is left out of the kernel.
- **Block layout** (`blk`): both A and C are blocked per 8 rows: `At[(m/8)*K*8 + k*8 + r]`, and the inner loop reads `At`
  contiguously in k; C is stored blocked as in `stc`.

| K | vec-n | vec-m | nost | stc | noT | blk |
| --- | --- | --- | --- | --- | --- | --- |
| 8 | 38 to 44 | 56 to 59 | 34 | 32 to 35 | 53 to 56 | 33 to 34 |
| 12 | 61 to 89 | 54 to 59 | 53 to 57 | 54 to 59 | 53 to 57 | 62 |
| 16 | 79 to 81 | 63 to 73 | 80 to 83 | 59 to 88 | 64 to 79 | 78 to 79 |
| 24 | 81 to 97 | 94 to 107 | 110 to 113 | 90 to 103 | 105 to 107 | 84 |
| 32 | 118 to 129 | 139 to 158 | 142 to 152 | 135 to 151 | 139 to 159 | 128 |
| 64 | 340 to 449 | 507 to 628 | 484 to 605 | 494 to 623 | 501 to 616 | 360 to 362 |

What this says:

- **K = 8:** the gap is the 1 KB stride of the C stores. Contiguous stores or no stores bring vec-m to vec-n's level.
  The transpose is not the cause (noT is no faster).
- **K = 24 to 64:** the stores and the transpose are not the cause, and packing B did not help either. The block layout
  for A closes the gap: the inner loop reads `At` contiguously in k instead of 1 KB apart, and blk matches vec-n at
  K = 64 and beats it at K = 24.
- **K = 16 is unexplained:** blk is slower than stc there (about 79 vs 58 µs). I have not found why.
- **Decision (allow blocked):** the layout model allows a blocked storage for the lanes-on-M data: A's transpose and C
  are kept in 8-row blocks (`Storage::Blocked8` in `nfcuop_layout.hpp`). It is an option of the emitter, and the
  default stays strided. The cost model still does not price storage; see the timings below.

## The emitter's blocked storage (fifth round)

`emit_gemm_rowsum_c(VecM, M, N, K, simd_transpose, Storage::Blocked8)` stores A's transpose and C in 8-row blocks, so
the inner loop reads `At` and writes C contiguously. The test (`tests/uop/test_layout_avx2.cpp`) checks both storages
bit for bit against the reference. The timings are of the emitter's own kernels, `M = N = 256`, best of 15 timings of
50 calls each, one run per flag set. The ratio is blocked / vec-n:

| K | -O2 | -O3 |
| --- | --- | --- |
| 8 | 1.00 | 0.82 |
| 16 | 0.98 | 0.77 |
| 24 | 0.92 | 0.92 |
| 32 | 1.16 | 1.03 |
| 64 | 1.00 | 1.07 |

What this says: blocked storage removes the M-vectorized penalty at K = 8 to 24 at both flags, and at K = 16 and
K = 8 it is the faster kernel at -O3. At K = 32 and 64 it is at parity or slightly slower. The N-vectorized kernel
is still the simpler choice where its speed is the same. The vec-n baseline at K = 8 varied from about 40 µs to 63 µs
between sessions on this host, so the K = 8 ratio is the least certain entry.

The scratch kernels and the driver are not in the repository.

## Optimization level changes the small-K results (fourth round, quiet host)

All timings above used `cc -O2`, the same flags as the emitter's test. Re-timing vec-n and vec-m at `-O3` (`M = N = 256`,
best of 15 timings of 50 calls each, one run per flag set, both runs for `-O2` agree within a few percent):

| K | vec-m / vec-n at -O2 | vec-m / vec-n at -O3 |
| --- | --- | --- |
| 4 | 1.03 | 2.43 |
| 8 | 1.47 | 1.28 |
| 12 | 0.85 | 0.94 |
| 16 | 0.89 | 0.95 |
| 24 | 1.12 | 1.12 |
| 32 | 1.16 | 1.17 |
| 64 | 1.46 | 1.47 |

What this says:

- **The K = 12 to 16 advantage for vec-m is small and only holds at -O2 (0.85 to 0.89) or at near-parity at -O3 (0.94
  to 0.95).** At K = 16 the block-layout kernel is 79 µs at -O2 and 53 µs at -O3, so the unexplained K = 16 result above
  is a code-generation effect of -O2 on the inner loop, not a layout effect.
- **K = 4 is not stable:** 1.03 at -O2 and 2.43 at -O3. The earlier 1.5 and parity readings were both at -O2 on a
  busier host. I do not have a reliable small-K number.
- **Above K = 16, vec-n is faster at both flags** (1.12 to 1.47 times vec-m), which the model also predicts.
- **Below K = 16, the model predicts vec-m wins.** The data do not show that: vec-m is slower at K = 8 at both flags.

Consequence: on this AVX2 target, for this shape, the N-vectorized kernel is the faster default at almost every K. The
M-vectorized kernel only competes with a blocked layout (see the block experiment above), which the layout model does
not describe yet.

## Against a vendor BLAS (AVX2, 512 x 512 x 512, float32)

The comparison is with OpenBLAS through numpy, on this host. Timings are best of 10 to 30 calls; the host was quiet
(load about 0.3). The packed kernel packs B inside the timed call.

| kernel | us | vs OpenBLAS 1 thread | vs OpenBLAS 4 threads |
| --- | --- | --- | --- |
| emitter VecN (no blocking) | 23,100 | 12.6x slower | 44x slower |
| emitter VecM, strided | 21,100 | 11.5x slower | 40x slower |
| register-blocked 4 x 16 (hand written, unpacked B) | 4,900 to 6,900 | 2.7x to 3.7x | 9x to 13x |
| emitter packed 4 x 16 (`emit_gemm_rowsum_packed_c`) | 4,000 | 2.2x | 7.6x |
| OpenBLAS, 1 thread | 1,840 | 1x | |
| OpenBLAS, 4 threads | 531 | | 1x |

The OpenBLAS 1-thread time varied between sessions (1,880 to 3,010 us), so the ratios are rough.

What the steps show: register blocking (one loop iteration updates a 4-row by 16-column tile) gives most of the gain.
Packing B so the inner loop reads it contiguously gives about 20 percent more. The remaining gap to one thread is
the tile size (6 x 16 uses more accumulators on AVX2), the lack of K blocking, and the packing pass.
Four-thread OpenBLAS is outside what this kernel does; it is not a fair comparison for a single-threaded kernel.

Packing B is also the layout repair of the model: a transform of the data so that the inner loop's accesses are
contiguous. The model does not price it yet.

## Corrected comparison: AVX2 against AVX2 (sixth round)

The earlier table compared an AVX2 kernel with OpenBLAS choosing its kernel itself. On this host (AVX-512 capable)
OpenBLAS uses AVX-512 kernels by default, so that comparison was not like for like. Forcing OpenBLAS to its AVX2
kernels (`OPENBLAS_CORETYPE=Haswell`, one thread, 504 x 512 x 512, float32):

| kernel | us | vs OpenBLAS AVX2 |
| --- | --- | --- |
| emitter packed 4 x 16 (`emit_gemm_rowsum_packed_c`, mr = 4) | 3,786 | 1.16x slower |
| emitter packed 6 x 16 (`emit_gemm_rowsum_packed_c`, mr = 6) | 3,305 | parity |
| OpenBLAS, AVX2 kernels (Haswell) | 3,276 | 1x |
| OpenBLAS, AVX-512 kernels (SkylakeX) | 1,825 | 1.8x faster |

So the AVX2 path is at parity with OpenBLAS's AVX2 kernels on one thread. The gap that remains is to the AVX-512
kernels, which use 16-lane vectors this path does not emit.

K blocking (the packed panels kept in cache, with C accumulated across blocks in memory) did not help: 3,486 us with
no blocking, 3,550 us at a block of 256, 3,507 us at 128. At these sizes the packed panel already stays in cache, and
the extra loads and stores of C cost what the blocking saves.

## AVX-512 packed kernel (seventh round)

`emit_gemm_rowsum_packed512_c` (`lib/uop/nfcuop_layout_avx512.*`) is the packed kernel on 16-lane zmm vectors: a
mr-row by 32-column tile over 32-column packed panels of B, mr = 4 or 6. The test (`tests/uop/test_layout_avx512.cpp`)
checks it bit for bit against the reference and skips without AVX-512F.

504 x 512 x 512, float32, one thread, the same host:

| kernel | us | vs OpenBLAS AVX-512 (SkylakeX) |
| --- | --- | --- |
| emitter packed AVX-512, mr = 4 | 2,016 | 1.13x slower |
| emitter packed AVX-512, mr = 6 | 2,163 | 1.22x slower |
| OpenBLAS, AVX-512 kernels | 1,778 | 1x |
| OpenBLAS, AVX2 kernels (Haswell) | 3,337 | 1.6x faster than the AVX-512 kernel |

So the AVX-512 kernel is within about 15 to 20 percent of OpenBLAS's AVX-512 kernels on one thread, and it is the first
path here that is not limited by the 256-bit vector width. Single-thread OpenBLAS measurements varied between sessions
by about 30 percent, so treat the ratio as rough. Threading and tile shapes other than 4 and 6 rows are not done.

## The solver drives the emitter (eighth round)

The solver now has a third GEMM variant, `avx2-packed-n`: the register-blocked 6x16 kernel. It takes B in a new storage,
`Storage::Panel16` (B packed into 16-column panels). A variant declares that storage with `Variant::requires_storage`;
solve() charges the packing copy (numel * `panel_instr_per_elem`, one load and one store per ymm, 0.25 per element) and
records it in `Solution::storage`. The variant exists only when M % 6 == 0 and N % 16 == 0, the shapes its emitter takes.

Its FMA cost is `fma * register_blocked_fma_factor`, with the factor at 0.18. That factor is fitted, not derived, and it
is the only thing that makes the packed variant win. Measured at 504 x 512 x 512 on one thread (the same host state, best
of 40): the naive VecN kernel 14848 us, the packed kernel 2623 us, a ratio of 0.177. The packing copy is a small term
(65536 instructions against about 16.5 million FMAs), so almost all of the gain is register blocking, which the
instruction-count model cannot see. Setting the factor to 1 makes the solver keep the naive kernel
(`test_layout.cpp`, `packed_needs_its_factor`). So the solver's choice of the packed kernel is a measured constant, not a
prediction from the layout.

`emit_for_solution(Solution, M, N, K)` maps the plan to an emitter: (vec-n, reduce-horizontal) to the VecN emitter,
(vec-m, reduce-vertical) to VecM with the storage the plan holds for C (A^T must match it, and Panel16 is refused), and
(packed-n, reduce-horizontal) to the threaded packed emitter, which needs B in Panel16. Any other combination throws
`std::invalid_argument`; the rowsum variant has to match, because the emitters fold the row sum into the kernel.

`tests/uop/test_layout_avx2.cpp` solves four shapes, emits each plan, compiles it and checks it against the reference:
48 x 64 x 17 (packed), 16 x 24 x 64 (VecN), 16 x 24 x 5 and 64 x 64 x 8 and 256 x 256 x 8 (VecM, Blocked8 in all three,
since the model prices blocked lanes-on-M storage at zero). The strided VecM path is covered by the direct emitter cases,
not by a plan, because the model does not choose it at these shapes.

What the model does not do: thread count (the packed plan runs on whatever `nthreads` the caller passes), cache effects
beyond the register-blocking constant, and the AVX-512 target.

## Threads in the model (ninth round)

`Avx2F32::max_threads` (default 1) lets the solver pick a thread count for the threadable packed variant. The packed
FMA work W is split as `W * (serial_fraction + (1 - serial_fraction) / t) + thread_spawn_instr * (t - 1)` over powers of
two up to `max_threads`, and `Solution::threads` reports the count. The caller passes that count as the kernel's `nthreads`.
Default 1 keeps every plan as it was.

The constants are fitted to one host's timings at 504 x 512 x 512 (packed kernel, best of 40), and they are rough:

| run | 1 thread | 2 threads | 3 threads | 4 threads |
|---|---|---|---|---|
| fit run | 2468 us (1.00) | 1485 us (0.60) | not measured | 1183 us (0.48) |
| check run | 2316 us (1.00) | 1349 us (0.58) | 1008 us (0.44) | 848 us (0.37) |

The fit (`serial_fraction` 0.10, `thread_spawn_instr` 154000) was made from the fit run, which gives 0.60 and 0.48 at two and four threads. The
check run was not used in the fit. It shows the four-thread ratio moving from 0.48 to 0.37 between runs, and the
three-thread value (0.44) is below the fit's 0.50. So the four-thread ratio is uncertain by about 0.1 on this host, and
the model's choice of four threads rests on constants that this noise is as large as. Treat `max_threads` as a knob,
not as a prediction.

Unchanged: the emitter does not know the thread count, so `emit_for_solution` output is the same for every plan.

## Next steps on this target

1. Price the register-blocking gain from a layout property rather than a fitted constant, so the solver can predict it for
   other shapes and targets. This is the weakest part of the model right now.
2. Repeat the timing on more hosts before drawing a crossover from it.
3. Measure the thread constants on a quiet host with more repetitions, and at 3 and 8 threads, before relying on the
   thread choice (see the ninth round).
4. AVX-512 as a second target description (16 lanes, `vpermt2ps`-based transposes), to see whether the model's shape holds.

## Tests

`tests/uop/test_layout.cpp` (the model) and `tests/uop/test_layout_avx2.cpp` (the emitter), both run by
`tests/uop/run.sh` (`UOP_ONLY="test_layout test_layout_avx2"`). Neither needs an nfcxx build; the emitter test needs a C
compiler with AVX2 and FMA (it prints SKIP on a CPU without them).

## References

- Ma, Chen, Li, Luo, Xiao, Zheng, Li, Liang. "Retargetable Compilation for Tensor Kernels via a Unified Layout Abstraction" (Arknife). arXiv:2611.13741 [cs.PL], 2026. https://arxiv.org/abs/2611.13741
