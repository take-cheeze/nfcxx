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
