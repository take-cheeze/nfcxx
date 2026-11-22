# SHAVE measurement probes

Timing probes for the Intel NPU from Linux, built with the same pinned MoviTools toolchain as `run_kernel.py`.
Each probe checks its output bit for bit against numpy and reports a marginal cost (slope of p50 against a
size parameter), so the fixed inference overhead cancels out.

Run from this directory, with the OpenVINO NPU environment and MoviTools available:

    python3 probe_chain.py  <movi-root> <wine-host>   # dependent vs four interleaved integer chains
    python3 probe_float.py  <movi-root> <wine-host>   # the same with float32 chains
    python3 probe_vec.py    <movi-root> <wine-host>   # 128-bit vector loads (ext-vector type)
    python3 probe_cmp.py    <movi-root> <wine-host>   # vector add with and without a compare and select
    python3 probe_synth.py  <movi-root> <wine-host> [chain,wide,wide_mem,wide_gload]  # straight-line float statements

`depth.py <frame_programs.h> <row>` reports the longest read-after-write chain of one pixel of an emitted
npu-render row (a rough estimate: write-after-write and write-after-read are ignored).

Notes:
- Build and run long jobs detached; a tool call that waits for them can time out.
- A hand-written assembly kernel with five or more straight-line ops hung the NPU in our tests, so the probes
  use C that the compiler lowers, not hand-written bundles.
- Use a struct type for vectors only if you want scalar code; `ext_vector_type(4)` emits 128-bit loads and VAU ops.
- Measured on Intel Core 3 304 with NPU PCI 8086:fd3e, OpenVINO 2026.4.1 (see the PR description for numbers).
