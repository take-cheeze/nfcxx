# Linux NPU runner (experimental)

Runs a SHAVE kernel on an Intel NPU from Linux: compile it with the pinned MoviTools toolchain
through wine, patch it into an OpenVINO-exported NPU blob, and run the blob on the device.

## Pipeline

1. OpenVINO exports an FP16 add model as an NPU blob (the base carrier).
2. `npubuild.exe` (built from `npubuild.c` with mingw) compiles, assembles and links the kernel with
   the MoviTools DLLs under wine, using the same compiler flags, target and linker script as the pinned
   build. `hazards.py` inserts the NOPs the assembler's write-port check requires.
3. The carrier's `shave.text` section is replaced with the kernel's text.
4. The patched blob is imported into OpenVINO on the NPU, run once, and checked.

## Usage

Requirements: OpenVINO with the NPU plugin, MoviTools (`moviCompile64.dll`, `moviAsm64.dll`,
`moviLLD64.dll` in `<movi-root>/bin`, not included), wine, and mingw-w64 to build `npubuild.exe`.

```sh
x86_64-w64-mingw32-gcc -O2 -o host/npubuild.exe npubuild.c
python3 run_kernel.py examples/fill.c --movi-root ~/movitools/MVC_DEPEND --wine-host host \
    --elements 8 --expect 1.5 --bench 300
```

`examples/fill.c` writes FP16 `1.5` to every output element; `--expect 1.5` checks that the patched
kernel ran. The bench loop reports per-call latency. For a tensor this small, the number is mostly fixed
per-call overhead, not kernel time.

## Status and limits

- Verified on takecheeze-h8 (Panther Lake NPU, OpenVINO 2026.4.1): the example kernel compiles, links,
  patches and runs, and the output matches (`PASS`).
- **Experimental, not qualified.** `npu_render`'s own carrier contract (`ptl_carrier.py`) accepts only
  a six-invocation carrier, and that is what the qualified Windows route uses. The base blob exported on
  Linux has two invocations, so this runner tests execution, not the qualified contract.
- The base add model is compiled for the requested element count; the example kernel hard-codes 8
  elements, so use `--elements 8`.
- Kernel size is limited to the base carrier's `shave.text` section (26,624 bytes for the 8-element model).
  The frame kernel (about 106 KB) does not fit this carrier.

## Comparing two kernels

`bench_kernels.py` builds two kernels that compute the same function, runs each on the NPU, checks every
output word against numpy, and times the inference. The two examples compute `out = in*3 + 7` on each
32-bit word of 8,192 FP16 elements:

- `examples/bench_lanes.c`: per-lane loops over small arrays (the style of `NR_V4_OP` in npu-render).
- `examples/bench_vector.c`: one 4-lane vector operation per group.

`--repeat` runs the loop several times inside one inference, so kernel time shows above the fixed per-call
overhead (about 0.2 ms here).

```sh
python3 bench_kernels.py examples/bench_lanes.c examples/bench_vector.c \
    --movi-root ~/movitools/MVC_DEPEND --wine-host host --elements 8192 --repeat 64 --bench 300
```

Measured on takecheeze-h8, three runs with the kernel order swapped, 64 passes each:

| kernel | text | p50 (ms) | min (ms) |
| --- | --- | --- | --- |
| `bench_vector.c` | 144 B | 1.655 – 1.667 | 1.637 – 1.643 |
| `bench_lanes.c` | 160 B | 1.742 – 1.746 (one run 1.98) | 1.687 – 1.729 |

Both kernels pass the word-for-word check. The vector form is about 4–5% faster per pass for this
integer kernel. That is one simple kernel, not npu-render's blend or composition code, so it does not
show what a rewrite would gain there.

## Larger kernels: growing the code window

`grow_carrier.py` enlarges the `shave.text` window of an exported blob, the same rewrite npu-render's
`grow_frame_carrier.py` does for its pinned carrier. `run_kernel.py` and `bench_kernels.py` take
`--window BYTES` (a 1 KiB multiple).

Checked on takecheeze-h8: a 131,168-byte kernel text (`examples/gen_lut.py`: a 32,768-entry lookup table,
which the linker places in the text section, plus a loop that reads it) patched into a 262,016-byte window
runs on the NPU, and all 4,096 output words match numpy.

Compiling large code is the limit, not the window: an unrolled integer chain of 1,500 steps peaked at
1.4 GB of compiler memory and 3,000 steps at 5.3 GB, and 6,000 steps ran out of memory on an 8 GB host.
A table keeps compile memory small, so use data for size tests.

The qualified frame kernel (about 107 KB) also needs the frame carrier's ABI and frame inputs. Neither is
covered here, so this shows the code window and loader accept a kernel of that size, not that the frame
kernel runs.

## npu-render's frame renderer on the NPU

`frame/gen_frame_fill.py` builds a synthetic frame batch with fill commands only, and the expected tile in
numpy. It inlines `frame_core.h` from an npu-render checkout (read at build time, not copied here), with an
entry that calls the real `nr_render_span`. `frame/frame_check.py` runs the batch on the NPU, checks the
output header and all 65,536 tile bytes, and times the inference.

```sh
python3 frame/gen_frame_fill.py <npu-render>/native/windows/ptl_kernels work/fill 1 64
python3 frame/frame_check.py work/fill --movi-root ~/movitools/MVC_DEPEND --wine-host host --bench 300
```

Measured on takecheeze-h8 (sequential runs, 300 inferences each):

| commands | status | tile | p50 (ms) | min (ms) |
| --- | --- | --- | --- | --- |
| 1 | 0 | 0 mismatches | 0.446 | 0.339 |
| 64 | 0 | 0 mismatches | 0.724 | 0.546 |

The renderer's text is 105,920 bytes with one hazard NOP. Per fill command the cost is about 4.4 µs
over a fixed overhead of about 0.44 ms (which includes the 264 KB transfer each way). The p90 varies
between runs (one run showed 17 ms), so compare p50 and min.

These are fill commands only. The shader path (native programs such as the blur and textured
composition) is not measured: it needs program records, vertex streams and textures in the batch.

## The shader path: solid-colour quads

`frame/gen_frame_quad.py` draws a full-tile quad per command, clipped to a random rectangle, with program
native 60 (38 + row 22: passthrough vertex stage, row 22 writes an immediate colour and does not sample).
The program record's signature is solved from the interpolation field to match `nr_native_check`.

Finding: in the NPU build, `nr_native_row` reaches `nr_row_22` through its nested dispatch tree with the
row argument wrong. `row->immediates` reads zero inside `nr_row_22`, but the value is correct at the entry
of `nr_native_row` and at the rasteriser's handoff. The same row called directly from the top of
`nr_native_row` gives the correct colour for every covered pixel. The generator now lowers the nested tree to a flat chain by default (`frame/flat_dispatch.py`), which
gives correct output without the shortcut. `--nested-dispatch` reproduces the original tree.

Measured on takecheeze-h8 (sequential runs, 300 inferences each, all tiles match, flat dispatch):

| draws | status | p50 (ms) | min (ms) |
| --- | --- | --- | --- |
| 1 | 0 | 0.469 | 0.433 |
| 16 | 0 | 0.982 | 0.830 |

About 32 µs per draw (two triangles each, row by row over the clip rectangle), against about 4.4 µs per
fill command. These numbers include the fixed inference overhead of about 0.44 ms.

```sh
python3 frame/gen_frame_quad.py <npu-render>/native/windows/ptl_kernels work/quad 1 16
python3 frame/frame_check.py work/quad --movi-root ~/movitools/MVC_DEPEND --wine-host host --bench 300
```

## Textured quads

`frame/gen_frame_textured.py` samples a 128x128 opaque texture in an atlas window through native 39
(38 + row 1: passthrough vertex stage; row 1 returns sample x varying 0, and varying 0 is 1.0 here). The
UVs are pixel centres over 128, so each covered pixel must return its own texel. All covered pixels match.

| draws | status | p50 (ms) | min (ms) |
| --- | --- | --- | --- |
| 1 | 0 | 0.685 | 0.526 |
| 16 | 0 | 1.193 | 1.153 |

About 34 µs per textured draw at p50 (solid colour: about 32 µs), against a fill command at about 4.4 µs.
The single-draw cost is higher than the solid quad's (0.685 ms against 0.469 ms), which points to a fixed
cost of the textured path per inference.

Not yet measured: blur (multi-pass) and bilinear minification; the sample here maps one texel per pixel.

## Lowering

`frame/flat_dispatch.py` flattens `nr_native_row`'s nested tree into `if (native == k) { nr_row_k(row); return; }`
for every row function present. It is applied to the generated entry for both the quad and textured batches.


## Where the per-pixel time goes (full-tile textured draws)

`--full-tile` makes every draw cover the whole 128x128 tile, so the per-pixel path dominates. Four
textured draws, 100 to 200 inferences each, sequential runs (p50):

| build | p50 (ms) |
| --- | --- |
| flat dispatch (default) | 42.06 |
| flat dispatch + vector lowering (`--vector`) | 41.73 |
| no blend (`NR_EXP_NO_BLEND` defined in the entry) | 27.08 |
| no pixel shader (`NR_EXP_NO_PS` defined in the entry) | 18.69 |
| neither | 2.24 |

Per pixel-draw (4 x 16,384 = 65,536 of them, out of 262,144 with fill-free overhead removed):
the blend is about 57 ns, the shader with texture sampling about 89 ns, and rasterisation with fixed
overhead the rest (about 2.2 ms in total, of which about 0.4 ms is the fixed inference cost).

Vector lowering of the four-lane helpers (`frame/vector_lower.py`) changes the time by about 1 %, which is
within noise, so the helpers are not where the time goes. The sampler (`nr_sample`, bilinear with four texel
fetches) and the blend are the candidates for lowering work. The ablation builds do not produce correct
pixels; only their timings are meaningful.

## Sampler lowering

`frame/sampler_lower.py` (`--sampler` in `gen_frame_textured.py`) gives `nr_sample` a block fast path: when the
four bilinear taps lie in the first window, one bounds check covers them and the four addresses are offsets from
one base. It is bit-identical (the tap addresses and escape counts do not change), and the four-tap batch
passes the exact texel check.

Four full-tile textured draws (p50, sequential runs):

| build | p50 (ms) |
| --- | --- |
| flat dispatch | 42.06 |
| flat dispatch + sampler block path | 41.60 |
| sampler replaced by a constant return (ablation, not correct) | 31.08 |

The bounds checks are not the cost: the block path gains about 1 %. The taps cost about 10.5 ms of the
41.6 ms (about a quarter), mostly the loads, unpacking and float conversions per texel, which the block path
keeps. The blend is about 15 ms and the remaining row maths and rasterisation about 16 ms. The next lowering
candidates are the per-texel conversion (convert the four texels as one block) and the blend.

## Blend lowering (copy mode)

`frame/blend_lower.py` (`--blend` in `gen_frame_textured.py`) adds a fast path to `nr_blend_pixel_alpha` for blend
mode 0 with all four write-mask lanes set. In that mode the source factor is exactly 255 and the destination
factor exactly 0, so the destination load and its select and shift terms add exactly zero. The fast path computes
the same value and rounding without them. The general path is unchanged after it, and other modes are unaffected.

Four full-tile textured draws, sampler block path on (p50, ms; baseline and candidate interleaved, NPU idle):

| build | run 1 | run 2 |
| --- | --- | --- |
| baseline (`--sampler`) | 41.29 | 41.78 |
| `--sampler --blend` | 38.00 | 37.96 |

About 8.5 % faster. The candidate matches the expected tile byte for byte.

The per-texel conversion pass tried alongside it (moving the channel swap onto the blended result) came out
about 3 % slower, so it is not included.

## Blend modes (general path timing)

`gen_frame_textured.py --mode N` sets the command's blend mode. Four full-tile textured draws, sampler on, blend
fast path off (so every mode runs the general path), p50 in ms:

| mode | p50 | mode | p50 |
| --- | --- | --- | --- |
| 0 | 41.90 | 8 | 41.68 |
| 1 | 41.57 | 9 | 41.42 |
| 2 | 41.84 | 10 | 41.23 |
| 3 | 41.46 | 11 | 41.15 |
| 4 | 41.34 | 12 | 41.17 |
| 5 | 41.62 | 13 | 41.95 |
| 6 | 41.61 | 14 | 41.47 |
| 7 | 41.56 | 15 | 41.54 |

All modes cost the same within about 2 %, so the general path's cost does not depend on the mode. Only modes 0,
1 and 14 match the copy-style expected tile; the others are timing-only (their outputs are not checked here). The
copy-mode fast path is therefore the only mode-specific saving so far.
