# Hardware measurements behind the GPU timing model

This note lists every number the timing model takes from real hardware, and where it came from. Nothing here was measured
in the session that wrote this note: the machine it ran on has no GPU (`nvidia-smi` is missing). Each entry cites the
change that recorded it.

## What has run on hardware

- **RTX 2060 (sm_75, driver 595, CUDA 13.2): the `mul2` GPU kernel, end to end.** The kernel is built from Path B IR to
  PTX (`tools/pathb-ptx-emit`), assembled by `ptxas`, and run through the CUDA runtime on 1000 elements, with its result
  checked. The mutants (a wrong multiplier, a missing bounds check) are caught. Source: `docs/notes/gpu.md`, "first step".
  This checks the code path. It does not measure time, so it gives no latency.

## Per-class latencies (RTX 5050, sm_120)

Measured by single-thread microbenchmarks (unrolled dependent chains, `clock64`). The microbenchmark source is not in the
repo. Source: PR #1682 (`perf/ptxi-calibrated-lat`), whose body records these numbers. They are the defaults of
`ptxi --timing` for the first six classes.

| class   | default (cycles) | measured (cycles)                                         |
|---------|------------------|-----------------------------------------------------------|
| alu     | 2                | about 2.1 per op                                          |
| local   | 40               | about 40                                                  |
| global  | 320              | 81 (16 KB), 316 (1 MB), 320 (64 MB)                       |
| atomic  | 31               | about 31 (uncontended)                                    |
| barrier | 24               | 24 / 30 / 86 (32 / 128 / 1024 threads)                    |

`global` is taken at 320 because most kernels miss L1. The 64 MB result is not explained, and may reflect the chase pattern.

## Not measured

- **branch, l1, l2.** Their defaults (4, 30, 120) are not measured. A loop cannot isolate a branch, and the L1 and L2
  latencies were not microbenchmarked.
- **Bandwidth and issue width.** `--bw`, `--gpu-bw` and `--issue` have no measured values.
- **Whole-kernel times.** No model estimate has been compared with a measured kernel time. The ranking check is the one
  that matters: run the same kernels (for example `mul2`, `exchange`, the barrier kernel) on a GPU, and compare the
  estimate's order with the measured order.
- **The H200 and Hopper results** quoted from the Theoric note are the note's own; they were not reproduced here.

## Reproducing the existing measurements

- The RTX 2060 check: `tests/gpu/run.sh` (needs `ptxas`, the CUDA runtime headers and `nvidia-smi`; it skips otherwise).
- The RTX 5050 numbers: rerun the microbenchmark described in PR #1682 on that card. Its source should be committed before
  these numbers are reused.
- The ranking check (not done): run the timing kernels on a GPU and record their times with `cudaEvent` timing, then compare
  the orders. The estimate is the `timing:` line of `ptxi --timing`.
