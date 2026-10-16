# uop perf: tinygrad WebGPU vs onnxruntime on numpy-style ops

Interpretation: the same float32 numpy-style operations (elementwise add, mul and sqrt; sum over the whole vector; square
matmul) written once for tinygrad and once for onnxruntime, timed on the same Mac. Scripts: `tests/uop/perf/`.

## Results (median of 10 runs after 3 warm-up runs; lower is better)

| op | size | tinygrad WebGPU (Chrome) | onnxruntime-web WebGPU (Chrome) | tinygrad CPU | onnxruntime CPU |
|---|---|---|---|---|---|
| add | 2^16 | 0.40 ms | 0.30 ms | 7.06 ms | 0.02 ms |
| add | 2^20 | 0.60 ms | 0.50 ms | 6.42 ms | 0.17 ms |
| add | 2^24 | 3.70 ms | 3.80 ms | 5.77 ms | 2.57 ms |
| mul | 2^16 | 0.40 ms | 0.30 ms | 5.75 ms | 0.02 ms |
| mul | 2^20 | 0.50 ms | 0.50 ms | 5.58 ms | 0.13 ms |
| mul | 2^24 | 3.40 ms | 3.10 ms | 5.85 ms | 2.55 ms |
| sqrt | 2^16 | 0.40 ms | 0.30 ms | 6.17 ms | 0.01 ms |
| sqrt | 2^20 | 0.60 ms | 0.40 ms | 6.88 ms | 0.38 ms |
| sqrt | 2^24 | 2.50 ms | 2.60 ms | 5.75 ms | 1.82 ms |
| sum | 2^16 | 0.30 ms | 0.40 ms | 3.59 ms | 0.01 ms |
| sum | 2^20 | 0.30 ms | 1.40 ms | 3.38 ms | 0.12 ms |
| sum | 2^24 | 1.40 ms | 15.80 ms | 3.85 ms | 1.96 ms |
| matmul | 256x256 | 0.50 ms | 0.40 ms | 5.82 ms | 0.03 ms |
| matmul | 512x512 | 0.60 ms | 0.50 ms | 16.31 ms | 0.26 ms |
| matmul | 1024x1024 | 2.10 ms | 1.80 ms | 172.29 ms | 2.10 ms |


Sizes are vector lengths for add, mul, sqrt and sum (2^16, 2^20, 2^24 float32 elements), and square matrices for matmul.

## Environment

- Chip: Apple M4 (macOS 26.5.2, Darwin 25.5.0). Chrome 155.0.8059.40, headless (`--headless=new`, `--use-angle=metal`).
- tinygrad 0.14.0 (WGSL renderer for the WebGPU path; CPU device for the CPU path).
- onnxruntime 1.31.0 (Python, CPU execution provider); onnxruntime-web 1.30.0 (WebGPU execution provider, loaded from jsdelivr).
- onnx 1.23.2 (models written with IR version 9), numpy 2.5.4.

## Method

- WebGPU, tinygrad: the kernels come from tinygrad's own WGSL renderer for each op (`gen_webgpu.py`, the same path as
  `tests/uop/tinygrad_compare`). The page times the whole kernel sequence: submit, then map one float of the output. The
  map waits for the queue, so the time includes the GPU work and the scalar readback.
- WebGPU, onnxruntime-web: the models run on the WebGPU execution provider. Inputs are GPU tensors made from our own
  buffers and the output stays on the GPU (`preferredOutputLocation: 'gpu-buffer'`), so the timed run has no host copy. The
  timing covers `session.run` plus the same one-float readback.
- CPU, tinygrad: `Tensor` ops realized, then one scalar that depends on the whole result is read (`out.sum().item()` for
  vector outputs). Without this, tinygrad can compute only part of a lazily sliced graph or return before its CPU kernels
  finish. The extra reduction is included in the tinygrad CPU numbers.
- CPU, onnxruntime: `InferenceSession.run` with NumPy inputs; the output is returned as a NumPy array.

## Caveats

- **tinygrad CPU numbers are overhead, not kernel speed.** They sit at 5–7 ms for every elementwise size, so they mostly
  measure per-call cost. Do not compare them with onnxruntime's CPU numbers as a throughput comparison.
- **The WebGPU numbers are on-GPU work plus one readback.** A readback costs roughly the same at every size, so small
  sizes are dominated by it. The 2^24 elementwise cases are memory-bound (about 200 MB of traffic per op) and sit near
  the same time for both frameworks.
- **sum is not the same kernel in the two frameworks.** tinygrad splits the reduction into 2 or 3 kernels (its real
  schedule, all counted). onnxruntime-web runs one ReduceSum kernel. At 2^24 onnxruntime-web takes 15.8 ms, about 11 times
  tinygrad's 1.4 ms; this is the largest gap in the table.
- **The output values of the WebGPU runs are not checked here.** Only the timing is measured; the earlier correctness
  checks in `tests/uop/tinygrad_compare` cover tinygrad's kernels on two small graphs, not these sizes.
- Chrome's `performance.now` is rounded to 0.1 ms, so the WebGPU rows at 0.3–0.6 ms carry about 15 % rounding error.
- Headless Chrome is not the browser users run; the numbers are for this build on this chip.
- The tinygrad WebGPU results are for the kernels as tinygrad renders them today (0.14.0); tinygrad's schedule can change
  between versions.

## Reproduce

```
TG_PY=<venv>/bin/python tests/uop/perf/run_webgpu.sh        # tinygrad WebGPU
TG_PY=<venv>/bin/python tests/uop/perf/run_webgpu_ort.sh    # onnxruntime-web WebGPU (ORT_WEB_VERSION overrides 1.30.0)
<venv>/bin/python tests/uop/perf/bench.py tinygrad CPU      # tinygrad CPU
<venv>/bin/python tests/uop/perf/bench.py onnxruntime       # onnxruntime CPU
```

Raw results are in `tests/uop/perf/results/`.

## Profiling the CPU runs

`NFCUOP_TRACE=FILE` makes `bench.py` write a Chrome trace-event JSON file (open in https://ui.perfetto.dev), in the format
of nfcxx's `--trace`. Spans are named `<backend> <op> n=<size> <phase>`: `build` (tinygrad's input tensors, named `inputs`;
onnxruntime's session creation), `warmup`, `run` (one timed call) and, for tinygrad, `readback` (the scalar read). Lowering
and code generation for tinygrad happen on its first call, so they appear inside the first `warmup` span; they are not
separate spans. The WebGPU runs (Chrome, `run_webgpu*.sh`) are not instrumented.

`tests/uop/perf/trace_test.sh` checks the file on a small configuration (`ORT_PY`, `TG_PY` choose the interpreters) and is run
by `tests/uop/run.sh`.
