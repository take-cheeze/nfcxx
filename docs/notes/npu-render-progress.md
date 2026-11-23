# npu-render on the Intel NPU from Linux: progress notes

Host: Intel Core 3 304, NPU PCI 8086:fd3e, OpenVINO 2026.4.1. Frame fixtures: npu-render `frame_kernel_test --fixtures`
(222 spans). Timings are p50 over repeated inferences; each probe checks its output bit for bit against numpy.

## Status

- All 222 npu-render fixtures run on the NPU from Linux and match the host reference bit for bit.
- The probes in `tools/npu-linux-runner/probes/` measure SHAVE costs. See that folder's README.

## Corrections to earlier figures

- The compose timings from a duplicate-process run were wrong. Clean reruns (1280x720, three layers, FP16, p50): NPU 8.6 ms, GPU 5.0 ms, CPU 4.6 ms.
- Fill spans: one and 64 fill spans cost the same within noise. A fill inference has a fixed overhead of about 0.4 ms. The earlier per-span figure (4.4 µs) is withdrawn.
- Row 14 (native 15) costs about 2 ns per executed bundle, not 12.6 ns. The earlier figure counted only the row's own bundles. The pixel loop calls out-of-line helpers 81 times per pixel (nr_sample 16, nr_v4_div 17, nr_v4_frc / nr_v4_cmp_ge / nr_v4_movc 16 each), and their bodies add about 7,100 bundles. Measured total is about 8,600 bundles per pixel in about 18 µs.

## Probe results (SHAVE, from C, unrolled where noted)

| Probe | Result |
|---|---|
| Integer chain, dependent vs four interleaved | 4.3 ns vs 1.0 ns per op |
| Float32 chain, dependent vs four interleaved | 8.5 ns vs 2.2 ns per mul+add step |
| Straight-line statements, chain / wide | 5.3 / 1.8 ns per statement |
| Local memory round trip (volatile buffer) | about +13 ns per statement |
| Unrolled 128-bit load + vector add | about 10 ns each |
| Loop with 128-bit load + add | about 33 ns per iteration (about 23 ns loop control) |
| Dependent-address load vs fixed | 45 ns vs 9 ns per step |
| Compare + select on one lane | about +8 ns per step |

A struct-typed vector compiles to scalar code; `ext_vector_type(4)` emits `LD.128` and `VAU` ops.

## Operations that are DPU vs SHAVE (profiled per graph)

- DPU: add, subtract, relu, clamp, average and max pooling, 3x3 and depthwise convolution, reduce sum and max over channels, transpose, multiply by a constant.
- SHAVE: tensor-by-tensor multiply, divide, maximum, minimum, sigmoid, exp, tanh, sqrt, abs, softmax, power (slowest).
- DMA: concat and split.
- The composition multiply stays on SHAVE in every graph variant tested.

## Ablations and experiments on the frame kernel (quad-ec1e65f6 rgba, p50)

| Variant | Time | Bit-exact | Notes |
|---|---|---|---|
| Baseline | 246 ms | yes | repeated runs agree within 0.1% |
| Row 14 blend removed | 228 ms | n/a | timing only |
| Row 14 constant loads zeroed | 107 ms | n/a | removes dependent work too; not a fix |
| Row 14 constant loads hoisted | 248 ms | yes | no gain |
| Row 14 invariant expressions hoisted | 248 ms | yes | no gain |
| Row 14 NOPs stripped | device error | n/a | NOPs are required latency padding |
| `nr_sample` inlined | 265 ms (+7%) | yes | kernel text 107 KB to 282 KB |
| `nr_sample` with one window check | 289 ms (+17%) | yes | more bundles per call |
| `nr_v4_movc` and `nr_v4_frc` inlined | 236.7 ms (−3.8%) | 222 of 222 | ready as a patch |
| `nr_v4_cmp_ge` inlined | 242 ms (−1.7%) | six spans | single run |
| Code-placement only (no code change) | ±3% | yes | placement noise floor |

Native 5 rgba (`e3ebf67c`) takes about 3,255 ms per span. Its loop 0 has 1,070 statements per iteration, and it runs the 16-iteration budget on every pixel. The budget is intended (npu-render confirmed). Helper inlining does not help this loop (+0.7%). About 10% of the loop body reads only loop-invariant values, so hoisting it would save at most that.

## Patches

- `inline-small-helpers.diff` (npu-render `frame_core.h`): inlines `nr_v4_movc` and `nr_v4_frc`. Applies cleanly to npu-render's source. Bit-exact on 222 fixtures. Ready for npu-render review; not applied.

## Open items

- Delta's `NPU_MAX_TILES`. The Linux device reports one tile; the Windows path uses three tiles and six engines. This is the largest factor and is a hardware question.
- Windows lab trace for the batching question: which `frame_batch_flushed` reasons dominate, and how many commands each flush carries.
- npu-render's answer to whether the Windows build dispatches natives 13 and up through the same tree mapping.
- Compose graph variants on the NPU (not started).
