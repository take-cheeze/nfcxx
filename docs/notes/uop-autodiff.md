# nfcuop autodiff: onnxsim's ONNX-level autograd on the `hir` graph (`lib/uop/nfcuop_onnxgrad.*`)

`np::grad(loss, {w1, w2})` (and `hir::gradients_via_onnxsim(g, loss, wrt)` under it) gives the gradient of a scalar float `loss`
as new values of the same graph. The differentiation is **not ours**: the sub-graph of the loss is exported as an ONNX model,
[onnxsim](https://pypi.org/project/onnxsim/)'s `graph_grad` appends the gradient as ordinary ONNX nodes, and the result is read
back into the graph. The gradient is therefore an ordinary value: lowered and evaluated by both back ends (interpreter, C),
exported with `to_onnx` next to the loss, accepted by `onnx.checker`, computed by onnxruntime, and differentiable again.

```cpp
Session np;  np.default_float = DType::Float64;
Tensor x = np.placeholder("x", {4, 3}), w = np.placeholder("w", {3, 2});
Tensor loss = -(onehot * matmul(x, w).softmax(1).log()).sum() / 4.0;   // LogSoftmax has no rule: Softmax, Log, a product
Tensor dw = grad(loss, w);                         // shape (3, 2)
Ts g = grad(loss, {w, x});                         // several at once: one call
np.save_onnx("m.onnx", {{"loss", loss}, {"dw", dw}});
```

## Why this replaced the native implementation

The first version (`nfcuop_grad.*`, removed) was our own reverse-mode pass with a rule for every `hir` operator. The decision was to
rely on a maintained ONNX-level autograd instead of a second implementation of calculus, and to check our graphs against it. The
price is the list under "What was lost" below: onnxsim deliberately differentiates only a slice of ONNX ("not an autograd
framework", its docstring says), and it is a third-party package that has to be present at run time.

## Architecture

```
np::grad ──► hir::gradients_via_onnxsim(g, loss, wrt)                      lib/uop/nfcuop_onnxgrad.cpp
              1. check loss (float, rank 0) and wrt (float); wrt outside the loss' sub-graph: zero (Expand of 0)
              2. Graph::to_onnx({loss})                                    the sub-graph of the loss, nothing else
              3. onnxsim  ── way 1: dlopen(libnfconnxsim.so)  ─► nfc_onnxsim_gradients()    scripts/onnxsim/nfc_onnxsim.cpp
                          └─ way 2: python3 scripts/onnx_grad.py (subprocess, temp files)    scripts/onnx_grad.py
              4. Graph::merge_onnx(result)                                 lib/uop/nfcuop_onnx_import.cpp
              5. the model's graph outputs (nfcg<N>_grad_<k>) are the gradients, in the order of `wrt`
```

**Which way is used when.** The C++ library is primary: `build/onnxsim/libnfconnxsim.so` (or the path in `$NFCUOP_ONNXSIM`) is
loaded with `dlopen` on first use. Only if it is absent, or this program cannot load it safely (below), the Python driver runs:
`$NFCUOP_PYTHON` (default `python3`) with `scripts/onnx_grad.py` (`$NFCUOP_ONNX_GRAD`), which needs `pip install onnx numpy
onnxsim==0.8.1`. `$NFCUOP_ONNXSIM_BACKEND=library|python` forces one. If neither works, `grad` throws `nfcuop::Error` saying what was
tried ("C++ library: ...; Python fallback: ...") and pointing here. `hir::onnxsim_available(&info)` tells beforehand. Both ways
run the same rules (the Python driver refuses every operator the C++ port has no rule for), and `tests/uop/test_grad.cpp` passes
with either (`NFCUOP_ONNXSIM_BACKEND=python`). Nothing of Python, onnx or protobuf is linked into `lib/uop`.

**The shim** (`scripts/onnxsim/nfc_onnxsim.cpp`, one C function): parses the forward `ModelProto`, runs ONNX shape inference,
keeps the nodes the loss needs and, among them, the ones that depend on a `wrt` (the slice to differentiate), seeds `d loss / d loss`
with a constant 1, calls `BuildBackward`, gives targets the loss does not reach a zero (it retries without them), inlines the
model-local functions of onnxsim's "templated" rules (`onnx::inliner`; they are written for opset 17 and inlined in a model of
their own), prefixes every new tensor name with `nfcg<N>_` (`N` = number of values of the graph, so repeated calls and second
derivatives never clash), and returns the forward nodes plus the gradient nodes with one `Identity` output per `wrt`.
onnxsim builds its constants and masks in float32, so a float64 model needs a fix that is not in 0.8.1:
`scripts/onnxsim/patches/0001-graph-builder-float-type.patch` (`GraphBuilder::SetFloatType`, proposed upstream, see
[onnxsim-upstream/README.md](onnxsim-upstream/README.md)) is applied on top of the pinned sdist by the setup script; without it the
gradients of a float64 model would not even type-check, and a mean's `1/N` would be off by 2e-8. (The Python driver converts the
emitted constants itself.)

**The build** (`scripts/setup-onnxsim.sh`, about 2 minutes, needs `cmake g++ protobuf-compiler libprotobuf-dev curl`): downloads the
PyPI sdist of onnxsim 0.8.1, **pinned by SHA-256** (patched only by the files in `scripts/onnxsim/patches/`) (`101c7b3d...b0a4`, it unpacks onnx 1.23.0 under `third_party/`), and builds
onnx, onnxsim's `graph_grad.cpp` and `qat_graph_builder.cpp` and the shim into one shared library against the system protobuf.
`ONNXSIM_SDIST=<file>` uses a local copy of the sdist. Exceptions of the library (every unsupported operator is one) are thrown and
caught inside it.

**nfcxx-built programs.** nfcxx emits weak, exported definitions of the C++ ABI's `type_info` vtables (without their virtual
functions) into every program; libstdc++ binds its exception machinery to them, so an exception thrown inside the loaded library
crashes in the unwinder. Such a program has to be linked with `-Wl,--version-script=scripts/onnxsim/exe.map` (nothing exported;
`tests/uop/run.sh` does this for `test_grad`). `nfcuop_onnxgrad.cpp` checks this at load time (`dladdr` of the vtable symbol) and
refuses the library otherwise, so a program linked without the script uses the Python driver instead of crashing.

## The importer (`Graph::merge_onnx`, `Graph::from_onnx`)

A hand-written protobuf reader, the counterpart of the writer. It reads: nodes, initializers (`raw_data` and the typed `float_data`,
`double_data`, `int32_data`, `int64_data` fields), graph inputs/outputs with static shapes, `Constant` nodes (all five `value*`
forms; they become initializers), attributes `INT INTS FLOAT FLOATS STRING TENSOR` (`hir::Attribute` has the new kinds and the
writer writes them), `ReduceMean/Max/Min` with `axes` as an attribute (opset 13 to 17), initializers that are also listed as inputs
(old IR). It rejects with a clear `Error`: opsets below 13, other domains, external data, dtypes other than float32/float64/int32/
int64/bool, dynamic dimensions, nodes with several outputs, unknown operators (the message of `add_node`).

Merging: a value whose name exists in the graph **is** that value (dtype and shape must agree, an initializer must have the same
content, an input must be an input: otherwise `Error` "name collision"); a node whose output exists is skipped; everything else is
appended with its name. Node names are unique in the graph (a repeated one gets a new name), automatic value names (`v<id>`) skip
names that came in. Export, import and export again give the same bytes (`tests/uop/test_onnx.cpp`).

No operator was added to `hir` for this: the gradient graphs of the supported forward operators use only `Add Sub Mul Div Neg Exp
Sqrt Transpose MatMul Reshape ReduceSum Greater Less Cast Identity Expand` (the last for the zero gradients) plus the clipping masks,
all of which `hir` has. (`Pad`, added earlier for the native `Slice` gradient, stays in `hir`; it is tested in `test_onnx.cpp`.)

## Operator coverage

| Operator | onnxsim 0.8.1 C++ rule | in `hir` | differentiated here |
| --- | --- | --- | --- |
| `Add Sub Mul Div Neg Exp Log Sqrt Sigmoid Tanh Relu` | yes | yes | yes |
| `Clip` | yes (strict inside; the bounds get no gradient) | yes | yes |
| `MatMul` | yes, 2-D and batched; **not** a 1-D operand | yes | yes (not 1-D) |
| `Transpose Reshape Identity` | yes | yes | yes |
| `ReduceSum ReduceMean` | yes | yes | yes |
| `Softmax` | yes | yes | yes |
| `Erf Gemm Gather Conv MaxPool AveragePool BatchNormalization InstanceNormalization LayerNormalization` | yes | **no** | forward operator missing in `hir` (follow-up: add them, the gradients then exist already) |
| `Abs Sin Cos Max Min Where Slice Concat Pad Expand Squeeze Unsqueeze ReduceMax ReduceMin LogSoftmax Cast` | no (a few exist in the Python package only) | yes | **no**: `Error` "no gradient rule for op type '...'" |
| comparisons, `Not And Or Xor`, `Mod` | no | yes | no: a mask made from a `wrt` (`x * (x > 0)`) is a path through `Greater` and `Cast`; the same masks off the path of every `wrt` are fine |

Layer normalization written with `mean`/`sqrt`/`div` (as in `layernorm` of the tests), attention with `softmax(q k^T) v`, MLPs with
`tanh`/`relu`/`sigmoid`, softmax cross entropy written as `-(onehot * softmax(z).log()).sum()` all differentiate.

The rules onnxsim has are *its* conventions: `relu'(0) = 0`; `Clip` passes the gradient only strictly inside the bounds (an `x`
equal to a bound gets 0, the native rule used the closed interval) and gives the bounds a zero gradient; `Softmax` and the rest
are exact.

## What was lost compared with the native implementation

Honestly, a lot of operator coverage, in exchange for not owning the rules:

* No gradient for `Abs`, `Sin`, `Cos`, `Max`/`Min` (binary), `Where`, `Slice`, `Concat` (hence `stack`), `Pad`, `Expand`
  (hence `broadcast_to`), `Squeeze`, `Unsqueeze`, `ReduceMax`, `ReduceMin`, `LogSoftmax`, `Cast`, and a 1-D `MatMul` operand
  (`dot` of vectors, matrix-vector products). Of the 100 finite-difference cases of the native test-suite 50 still differentiate.
* No second derivative of any of those (second derivatives of the supported operators work: `second-softmax-log`,
  `second-tanh-matmul` and others in `test_grad.cpp`).
* No gradient of the bounds of `Clip`, and no `Max`/`Min` tie convention (1/2 each) since there is no rule at all.
* Comparisons/casts of a `wrt` cannot be used as masks (`x * (x > 0).astype(float)`).
* The native pass skipped nodes that do not depend on a `wrt` itself; here the shim does the same (an unsupported operator off the
  path of the `wrt` is not reached, tested), but onnxsim refuses the *whole slice* if one dependent node has no rule, even where
  no gradient flows.
* Speed and size: the gradient is not optimized; the 2-layer MLP of the tests (11 forward nodes) gets 38 gradient nodes, the native pass 21. (Merging
  nodes is not done in `hir`; the UOp lowering interns equal nodes.)
* Float64 needs the upstream-proposed patch above (onnxsim 0.8.1 builds float32 constants); the Python package has no such option.
* A required run-time dependency: gradient computation runs a pinned third-party library (or Python package).

## Agreement with the native gradients

Before the native code was deleted, the 100 finite-difference models of its test-suite were differentiated by both and the
gradients compared in float64: for the 50 models onnxsim can differentiate the largest relative difference is **4.4e-17**
(identical to rounding), which also confirms the native rules for these operators; the other 50 hit an operator without a rule
(each reported with the library's message). Both the C++ library and the Python driver give the same gradients.

## Security and dependency notes

Computing a gradient executes third-party code: `libnfconnxsim.so` (built from the pinned onnxsim 0.8.1 sdist and its bundled
onnx, against the system protobuf) or the `onnxsim` Python package, with the files of a `mkdtemp` directory (removed afterwards)
as the only channel in the Python case. Pin it: the library script verifies the SHA-256 of the sdist, CI installs
`onnxsim==0.8.1`. The model that is handed over is produced by `to_onnx` from the user's own graph; the result is parsed by our
reader, which validates dtypes, shapes, names and operators and throws `Error` on anything else.

## Tests and why they SKIP

* `tests/uop/test_onnx.cpp` (no Python needed): round trips, merging, collisions, errors, `Pad`, and models made by the `onnx`
  package (`tests/uop/onnx_import_gen.py`: typed initializers, `Constant` nodes, attributes, float64/int32, slices) that are
  imported and evaluated against onnxruntime (those four skip with a SKIP line when python/onnx/onnxruntime are missing).
* `tests/uop/test_grad.cpp`: 59 finite-difference cases in float64 (866 derivative elements, largest relative error 1.3e-9),
  broadcasting in every binary operator, `MatMul` in six rank/batch combinations, reductions, layer norm, attention, two MLPs with
  softmax cross entropy, shared sub-expressions, second derivatives, hand-derived exact gradients, the 16 unsupported
  operators each with the library's message, argument errors, the gradient graph on the C backend equal to the interpreter bit for bit
  (16 arrays), and a child process for each "missing backend" message. It writes four gradient models
  (`grad_mlp grad_ops grad_matmul grad_second`) that `tests/uop/onnx_check.py` runs through `onnx.checker` (full check) and
  onnxruntime. **Without onnxsim** (neither `build/onnxsim/libnfconnxsim.so` nor python3 with onnx and onnxsim) the file prints
  `SKIP test_grad: onnxsim is not available (...)` after the argument checks and exits 0, so the suite stays green on a machine
  without it; `onnx_check.py` and `np_compat.py` skip without numpy/onnx/onnxruntime.
* CI (`.github/workflows/ci.yml`, job "nfcpoly, nfcast, mruby scripts", which runs `tests/uop/run.sh`) installs
  `onnx onnxruntime numpy onnxsim==0.8.1` with pip and builds/restores `libnfconnxsim.so` (cache key: hash of the setup script and
  shim) before the tests, so these tests run there.
