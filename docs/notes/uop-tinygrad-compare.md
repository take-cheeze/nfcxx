# uop WGSL and Metal renderers vs tinygrad's renderers

Compares `render_wgsl()` (lib/uop/nfcuop_wgsl.cpp) with tinygrad's own WGSL and Metal renderers on the two graphs of
tests/uop/test_wgsl.cpp. Run it with `TG_PY=<venv>/bin/python tests/uop/tinygrad_compare/run.sh`.

Versions: tinygrad 0.14.0 (pip, Python 3.14), headless Chrome over Metal on Apple M-series (adapter apple/metal-3).

## How tinygrad was driven

- The graphs are written as Tensor ops (`((x + y) * 2).sum(1)` and `(x.maximum(y) - (-y)) / (x * x + 1).sqrt()`).
- `Tensor.schedule_linear()` gives the kernels. Each kernel AST goes through `codegen.to_program(ast, renderer)`
  with `WGSLRenderer(Target(device="WEBGPU", renderer="WGSL"))` or `MetalRenderer(Target(device="METAL", arch="arm64"))`.
- The WGSL and Metal source is the `Ops.SOURCE` node of the program.

## What tinygrad does with the same graphs

| | ours (`render_wgsl`) | tinygrad 0.14 |
|---|---|---|
| graph A (add, mul x2, sum over axis 1) | 3 kernels, one per node, intermediates in buffers | 1 kernel: `((val2+val5+val0+val3+val1+val4)*2.0f)`, the sum runs over the raw inputs |
| graph B (7 nodes) | 7 kernels | 1 kernel: `select(...)` for max, `(alu1+val1)*(1/sqrt(val0*val0+1.0f))` |
| `a / b` | `b8[i] / b5[i]` | rewritten to `a * (1 / b)` |
| `a - (-b)` | a `neg` kernel then `sub` | folded to `a + b` |
| workgroup size | 64, guard `if (i >= n) return` | 3 for elementwise, 2 for reduce, dispatched over the grid |

Consequence: tinygrad's fusion and rewrites change float32 rounding, so its numbers differ from ours by one ulp.

## Numbers

Reference: our interpreter (`evaluate_array`), printed `expected` in the case file.

| graph | ours on WebGPU (earlier run) | tinygrad WGSL on WebGPU | tinygrad on its METAL device |
|---|---|---|---|
| reduce | bit-exact | PASS, 0 of 2 exact, max 2.4e-7 (one ulp) | 2.999999761581421, 1.1999999284744263 (= reference) |
| elementwise | PASS, 5 of 6 exact, max 2.4e-7 | PASS, 3 of 6 exact, max 2.4e-7 | matches reference (in float32) |

The strict float32 left-to-right evaluation of tinygrad's reduce expression gives 2.999999761581421, 1.1999999284744263,
the same as our interpreter. So on the WebGPU path tinygrad's kernel comes out one ulp high (3.0, 1.20000005) even though
its source has the same order and the same expression. A diagnostic with the sum fully parenthesized, left to right,
gave the same output. The cause is not isolated: candidates are the Tint-to-Metal path reassociating or contracting
the sum; this is unverified.

## Coverage (tests/uop/tinygrad_compare/coverage.py)

Tinygrad's WGSL renderer accepts graphs that our renderer refuses: permute (movement op), cast to int32, reduce max,
a bare leaf as root (0 kernels), reshape. Tinygrad refuses float64 (KeyError: dtypes.double), which is the same class of
refusal as ours. Dynamic (symbolic) shapes were not tested.

## Recommendation

- Use tinygrad only for comparison. Its WGSL output is shaped for its own scheduler (fused kernels, reciprocal
  multiplies, folded negations), which breaks the one-node-per-kernel mapping that our goldens and the ULP-exact
  checks rely on. Adopting it as our renderer would change numerics and goldens for no gain in coverage on these graphs.
- Keep `render_wgsl`. Its extra coverage (for example, the refusals of unsupported dtypes and movement ops) is a matter of
  choice. tinygrad's broader coverage (permute, int casts, reduce max) would be worth copying as kernels, not renderer output.
- Open question for the uop WebGPU path: the 1-ulp WebGPU gap for tinygrad's fused reduce. It is not a bug in our code.
