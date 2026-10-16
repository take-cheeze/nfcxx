# uop performance: the numpy-style benchmark (nfcxx's `np` API)

These numbers come from `tests/uop/perf/bench_np.cpp`, which writes every case with nfcxx's numpy-like API (`nfcuop::np`).
Each case is one expression over float32 placeholders, run on the four back ends the numpy `Session` has, from the same
program:

- **interpreter**: `Session::eval_all` with `Backend::Interpreter` (the reference).
- **C backend**: `render_c` and `CModule::compile` once, then `CModule::run` per timed call (`Backend::C`).
- **ONNX Runtime**: `Backend::Ort`, onnxruntime 1.31.0 (CPU provider) through `NFCUOP_ORT_LIB`.
- **tinygrad**: `Backend::Tinygrad`, tinygrad 0.14.0 on its CPU device, through `NFCUOP_TINYGRAD_PYTHON`.

The measurements are the median of 10 timed runs after 2 warm-up runs (the 1024 matmul on the interpreter has 0 runs, and the
512 matmul on the interpreter has 3). Each back end's output is checked against the interpreter. The 1024 matmul has no
interpreter result (see below), so its reference is the C backend.

## Results (Apple Silicon, 16 GB; times in ms, median)

| op | n | interpreter | C backend | ONNX Runtime | tinygrad (per call) | WebGPU |
|---|---|---|---|---|---|---|
| add | 65536 | 0.959 | 0.530 | 0.218 | 242.4 | not timed |
| add | 1048576 | 6.138 | 4.728 | 3.383 | 267.6 | not timed |
| add | 16777216 | 98.7 | 62.3 | 53.8 | 700.4 | not timed |
| mul | 65536 | 0.360 | 0.528 | 0.438 | 243.2 | not timed |
| mul | 1048576 | 6.203 | 4.700 | 3.415 | 267.5 | not timed |
| mul | 16777216 | 99.0 | 62.2 | 53.8 | 696.4 | not timed |
| sqrt | 65536 | 0.260 | 0.418 | 0.340 | 240.4 | not timed |
| sqrt | 1048576 | 4.468 | 3.745 | 2.778 | 260.3 | not timed |
| sqrt | 16777216 | 72.5 | 53.4 | 45.9 | 595.8 | not timed |
| sum | 65536 | 1.412 | 0.124 | 0.085 | 439.2 | refused (RESHAPE) |
| sum | 1048576 | 22.3 | 2.114 | 0.875 | 445.2 | refused (RESHAPE) |
| sum | 16777216 | 357.6 | 17.5 | 10.1 | 554.2 | refused (RESHAPE) |
| matmul | 256 | 516.7 | 9.854 | 0.247 | 345.9 | refused (RESHAPE) |
| matmul | 512 | 8008.6 | 80.4 | 1.059 | 354.8 | refused (RESHAPE) |
| matmul | 1024 | skipped | 831.1 | 4.856 | 376.1 | refused (RESHAPE) |

## Correctness against the interpreter

- **C backend:** bit-exact for every case.
- **ONNX Runtime and tinygrad, elementwise:** bit-exact for add, mul and sqrt. The sum differs in the last bits (relative error
  up to 6.6e-5 at 2^24, from the order of the float32 accumulation).
- **Matmul:** the per-element relative error is not a useful measure, because the sums of sin and cos values cross zero. The
  error scaled by the largest reference magnitude is about 2e-6 for ONNX Runtime and tinygrad at 256 and 512, and the C backend
  is bit-exact. Against a float64 reference (the C backend in float64), every back end is within about 4e-6.

## What the numbers mean

- **C backend times include the feed and result conversions.** `CModule::run` takes and returns `Array` values, so the copy
  into and out of the back end's buffers is inside the timed call. That is why the C backend's sum (one output element) is
  much faster than its add (a full output vector). The C kernels themselves are not isolated by this run.
- **tinygrad times are dominated by a fixed per-call cost** of about 240 ms for any size up to 2^20 (the helper runs each call
  in Python). They are not kernel speed, and should not be compared with the other columns.
- **The interpreter's 1024 matmul is skipped.** Its lowering is about 1e9 scalar operations and runs out of memory on this
  16 GB machine. The 512 matmul is about 8 s per run on the interpreter, so it gets 3 timed runs.

## WebGPU: not timed in this run

- `render_wgsl` refuses the `sum` and `matmul` graphs, because the numpy API lowers them through a reshape (`RESHAPE is not
  rendered`). Only add, mul and sqrt have WGSL modules, and those are written as cases for `tests/uop/perf/run_webgpu.sh`.
- The timing page (`tests/uop/perf/run_webgpu.html`) was not run successfully. On this Mac, headless Chrome's WebGPU adapter did
  not finish `requestDevice` during this session, and the existing correctness page (`tests/uop/wgsl/run.html`) also stopped
  at the same point, so the problem is the machine's headless WebGPU, not the page. The WebGPU results of earlier runs (#261)
  pass. This needs a rerun on a working Chrome before the WebGPU column can be filled in.

## Dawn (native WebGPU on Metal, local)

Run by `tests/uop/perf/dawn_bench.sh` (needs `DAWN_SRC` and `DAWN_BUILD`, see `tests/uop/wgsl/dawn/run.sh`). Chrome is not used.
Environment: Dawn source at `af01c4ef6` (a shallow clone, built with Metal only), adapter `apple/metal-3`, the same Mac as the
table above. Only add, mul and sqrt have WGSL modules (see above), so sum and matmul are not in this table.

The timing rule is the one in `run_webgpu.html`: the pipelines and bind groups are built once and the inputs uploaded before
the timer; each timed run encodes every kernel, copies one output value to a probe buffer, submits, and waits for the probe to
map. Two warm-up runs, then the median of 10 (min in the last column). Each case's output is checked against the interpreter
first: PASS means every value is within 1e-6 (absolute below 1, relative above 1), and `exact` counts the bit-exact values.

| op | n | Dawn median ms (min) | exact | interpreter ms | C backend ms | ONNX Runtime ms |
|---|---|---|---|---|---|---|
| add | 65536 | 0.206 (0.199) | 65536 / 65536 | 0.959 | 0.530 | 0.218 |
| add | 1048576 | 0.447 (0.385) | 1048576 / 1048576 | 6.138 | 4.728 | 3.383 |
| add | 16777216 | not run (DISPATCH_LIMIT) | | 98.7 | 62.3 | 53.8 |
| mul | 65536 | 0.213 (0.202) | 65536 / 65536 | 0.360 | 0.528 | 0.438 |
| mul | 1048576 | 0.440 (0.428) | 1048576 / 1048576 | 6.203 | 4.700 | 3.415 |
| mul | 16777216 | not run (DISPATCH_LIMIT) | | 99.0 | 62.2 | 53.8 |
| sqrt | 65536 | 0.463 (0.250) | 48644 / 65536 | 0.260 | 0.418 | 0.340 |
| sqrt | 1048576 | 0.383 (0.305) | 779046 / 1048576 | 4.468 | 3.745 | 2.778 |
| sqrt | 16777216 | not run (DISPATCH_LIMIT) | | 72.5 | 53.4 | 45.9 |

- **The 2^24 cases are not run.** Dawn accepts at most 65535 workgroups along one dimension. `render_wgsl` emits 64-wide
  workgroups and the dispatch is one-dimensional, so 2^24 elements need 262144 groups, and validation refuses the dispatch.
  Chrome's WebGPU would refuse the same dispatch, since the module is the same. Fixing it means changing the emitter (a 2-D
  dispatch, or a larger workgroup), which is not done here. The other columns are from the table above, not re-run in this
  session.
- **sqrt is not bit-exact** on Metal: about 74% of values match the interpreter exactly, and the rest are within the 1e-6
  relative tolerance. add and mul are bit-exact.
- **Timing noise:** the sqrt 65536 median (0.463 ms) is above its 1048576 median, while its minimum is 0.250 ms. Small-size
  timings are noisy on this machine; read the minimum next to the median.
- **Not like-for-like with the C backend.** The Dawn timed run reads back one value, while the C backend's run includes the
  conversion of every input and output (see above). The Dawn number is the kernel dispatch plus the submit and the wait, not
  a full-output transfer.
- **Chrome WebGPU column for the numpy API:** still not timed (see above), so this table has no Chrome row to compare with.

## Reproducing

    c++ -std=c++17 -O2 -Ilib/uop <the lib/uop sources listed in tests/uop/perf/trace_test_np.sh> \
      tests/uop/perf/bench_np.cpp -o bench_np
    export NFCUOP_ORT_LIB=/path/to/libonnxruntime.dylib NFCUOP_TINYGRAD_PYTHON=/path/to/python3
    ./bench_np > results.jsonl                         # all cases (the 2^24 vector and 1024 matmul take minutes)
    ./bench_np --only=add --max-n=65536                # one case
    NFCUOP_TRACE=trace.json ./bench_np --only=add      # Chrome trace-event JSON (open in ui.perfetto.dev)
    tests/uop/perf/trace_test_np.sh                    # checks the trace on every back end the Session has
