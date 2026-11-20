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
