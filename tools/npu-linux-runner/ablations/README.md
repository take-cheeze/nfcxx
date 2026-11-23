# Frame-kernel ablation tooling

Scripts that build variants of npu-render's frame kernel for timing experiments on the NPU, and the patch that
came out of them. Each variant is a copy of npu-render's `ptl_kernels` directory with one change, compiled and
run through `frame/fixtures_check.py`.

Run them on the host where the NPU and MoviTools are set up. The scripts assume:

- npu-render's sources at `~/npu-render-work/src/native/windows`
- MoviTools at `~/movitools/MVC_DEPEND` and the Wine prefix `host`
- the fixture file at `~/shader-gen/fixtures.bin`
- variant copies under `~/ablate14/`

Scripts:

- `ablate14.py`: baseline plus row 14 variants (blend removed, constant loads zeroed).
- `hoist14.py`, `hoist2.py`: hoist row 14's constant loads, then its constant-only expressions, out of the pixel loop.
- `inline14.py`: `nr_sample` inlined, or helpers inlined.
- `helpers.py`: inline only the small helpers (`nr_v4_movc`, `nr_v4_frc`), or `nr_v4_cmp_ge`.
- `sampfast.py`: one window check for all four bilinear taps (rejected: slower).
- `pad.py`, `layout.py`: unexecuted copies of `nr_sample`, to separate code size and placement from executed code.
- `nopstrip.py`: strips row 14's NOP bundles before hazard fixing (timing only; the device fails).
- `lanedepth.py`: lane-level dependency depth of an emitted row, from the `depth.py` analysis.

Patch:

- `inline-small-helpers.diff`: inlines `nr_v4_movc` and `nr_v4_frc` in npu-render's `frame_core.h`. Applies cleanly
  to npu-render's current source (dry run). 222 of 222 fixtures bit-exact on the NPU. Quad-ec1e65f6 rgba p50
  246.0 ms to 236.7 ms. Not applied to npu-render.

`frame/fixtures_check.py` in this branch includes the `--vector-lower` option, the total-time line, and the
`NR_WINDOW` environment variable (grows the kernel's code window when a variant's text is larger than the
default window).
