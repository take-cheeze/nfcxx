# Real models on three back ends: onnxruntime, tinygrad, nfcxx's C backend

`tests/uop/perf/models/run.sh` times two models at batch 1 and batch 32, on onnxruntime (CPU), tinygrad 0.14 (its ONNX
frontend, `tinygrad.nn.onnx`, on its default device, METAL here) and nfcxx's C backend (`bench_models.cpp`: `hir::Graph::from_onnx`,
the `Lowerer`, then `Session::eval` with `Backend::C`). Every output is checked against onnxruntime; a back end that differs by
more than 1e-4 relative would be reported as wrong, and none did.

## Models

The repo has no `.onnx` files. The ONNX tests (`tests/uop/onnx_import_gen.py`, `test_onnx.cpp`) build single-operator graphs in
code, so none has real depth. `tests/llamacpp` is a llama.cpp check, not a model file. Both models here are exported by
`models.py export` with the `onnx` package, from seeded random weights (not a pretrained checkpoint):

| model | ops | parameters | file (batch 1) |
|---|---|---|---|
| mlp | Gemm, Relu, Gemm (784 → 256 → 10) | 203,530 | 814 KB |
| cnn | Conv, BatchNormalization, Relu, MaxPool (×2), Reshape, Gemm (1×28×28 → 16 → 32 → 10) | 20,684 | 84 KB |

The batch-32 files have the same ops and weights with the batch dimension changed.

## Median run time (ms), 10 runs after 3 warm-up runs

| model | batch | onnxruntime-cpu | tinygrad (METAL) | nfcxx (C backend) |
|---|---|---|---|---|
| mlp | 1 | 0.006 | 3.169 | 0.831 |
| mlp | 32 | 0.019 | 3.821 | 4.897 |
| cnn | 1 | 0.059 | 12.385 | 2.076 |
| cnn | 32 | 0.323 | 13.443 | 33.069 |

## Correctness (max relative error against onnxruntime)

| model | batch | tinygrad | nfcxx (C backend) |
|---|---|---|---|
| mlp | 1 | 7.6e-7 | 8.5e-7 |
| mlp | 32 | 4.1e-7 | 3.7e-7 |
| cnn | 1 | 3.7e-7 | 3.0e-7 |
| cnn | 32 | 1.5e-6 | 8.5e-7 |

## Not run, and why

- **nfcxx's ONNX Runtime back end (`nfcuop_ort`):** not timed. It exports the graph and runs it in onnxruntime, so it would only
  time onnxruntime again.
- **The UOp interpreter:** not timed. It is the reference the numpy benchmark uses, and the CNN at batch 32 is far too large
  for it to finish in a useful time. The C backend's outputs were checked against onnxruntime instead.
- **WebGPU:** not attempted for these models. Headless Chrome's WebGPU did not finish `requestDevice` on this machine (see
  `docs/notes/uop-perf-bench.md`), so there was no WebGPU run to time.

## Caveats

- **The nfcxx column includes `Session::eval`'s per-call work.** The timed call feeds the input and the weights, and converts the
  output to `Array`. The kernel alone was not timed, so the nfcxx numbers are an upper bound on the C backend's kernel time.
  The mlp batch-1 case is mostly that overhead: the kernel work is about 0.2 M multiply-adds.
- **tinygrad has a fixed cost of about 3 ms per call** on METAL (the same floor the numpy benchmark showed), so its mlp numbers
  say little about the kernels, and its cnn numbers include that floor.
- **onnxruntime's mlp time is small:** 6 µs for batch 1. It uses its default thread pool; no thread count was fixed.
- At batch 32 the CNN takes 33 ms on the nfcxx C backend against onnxruntime's 0.32 ms. The feed overhead was not measured,
  so this run does not say how much of the gap is the kernels.
- One Mac (Apple Silicon), one run of the script; the medians are of 10 runs and vary by a few percent between runs.

## Reproduce

```
PY_ORT=<python with onnx, onnxruntime, numpy> PY_TG=<python with tinygrad 0.14 and numpy> \
  PATH=<tinygrad venv>/bin:$PATH tests/uop/perf/models/run.sh
```

The script builds `bench_models` with the same library list as the other perf tools, exports the models into a temporary
directory, and prints one JSON line per model and back end, followed by the comparison.
