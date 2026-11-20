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
