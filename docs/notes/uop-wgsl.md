# WGSL rendering (WebGPU, macOS through Metal)

`lib/uop/nfcuop_wgsl.hpp` renders a UOp graph as a WebGPU compute shader (WGSL). It is the WebGPU counterpart of the C
renderer (`nfcuop_cgen.hpp`, docs/notes/uop.md, "C rendering"); the C backend is unchanged.

```cpp
nfcuop::WgslProgram p = nfcuop::render_wgsl(root);  // p.source: the WGSL module; p.kernels: in order; p.buffers
```

## What is rendered

- Float32 only. Elementwise ops: `Neg`, `Sqrt`, `Add`, `Sub`, `Mul`, `FDiv`, `Max`. And `ReduceSum` over any axes.
- Each operation node is one kernel (one `@compute` entry `k<id>`) with its own storage buffer `b<id>`. There is no fusion,
  so a node is computed once and every user reads its buffer. A `Var` is an input buffer named after the variable. A `Const`
  is a literal in the kernels that read it.
- A `ReduceSum` kernel has one invocation per output element. It starts from the first element of the reduced axes and adds
  the rest with nested loops over the reduced axes, outermost first, so the order is row-major as in `evaluate_array`.
- Movement ops (Reshape, Permute, Expand, Shrink, Pad, Flip), `ReduceMax`, the other ALU ops, and other dtypes are refused
  with `Error`. So is a non-finite constant (it has no WGSL literal here).

The kernels run in `WgslProgram::kernels` order. Each kernel binds only the buffers it reads or writes
(`WgslKernel::bindings`): a WebGPU stage allows 8 storage buffers by default, and a graph can have more than that.

## Running it (macOS)

`tests/uop/wgsl/run.sh` builds `tests/uop/test_wgsl.cpp` and then runs each generated module on WebGPU in headless Chrome
(`tests/uop/wgsl/run.html`). Chrome's WebGPU runs over Metal on macOS. The page compares each output with the interpreter's
value (`evaluate_array`, written into the case file). The reduce case matches bit for bit. Elementwise results can differ
from the interpreter by one float32 ulp, because WGSL does not require correctly rounded `sqrt` or division. The runner
allows 1e-6 relative error and prints the exact-match count.

Headless Chrome's virtual time budget can end before the GPU readback finishes. The page then still says "pending", and
`run.sh` retries it (at most three runs). A `FAIL` is never retried.

`run.sh` skips the WebGPU run when no Chrome is found (set `CHROME` to another one). The C++ golden check and the refusals
still run.

## Not covered

- Only validation in the golden test and the browser run; there is no other WGSL validator here (naga, tint and Dawn are
  not installed). Chrome's WebGPU compiler is the one that validates the modules.
- Not wired into `tests/uop/run.sh` or CI: the CI runners have no WebGPU adapter.
- Fusion, movement ops, reductions other than sum, integer and bool dtypes, and dynamic shapes are not rendered.
