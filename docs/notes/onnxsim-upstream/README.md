# Fixes for onnxsim found while using its C++ autograd from nfcuop

Seen in **onnxsim 0.8.1** (PyPI sdist `onnxsim-0.8.1.tar.gz`, SHA-256 `101c7b3d31e39c609cdfafddb4d3586572435f76f0e1a191d95d0a6797e1b0a4`, with the
onnx 1.23.0 it bundles under `third_party/onnx`). The patches are plain `diff -u` files (`patch -p1` from the root of the sdist), checked to
apply in order to the pristine sdist. They were built and run here against the sdist's own tests, compiled by hand with g++ 13 against the
bundled onnx and the system protobuf 3.21.12 (their CMake build, which needs ONNX Runtime sources or a release, was **not** run):

* `graph_grad_test` (extended by 0001), `qat_graph_builder_test`, `graph_grad_templates_test`: all pass with 0001 applied;
* `graph_grad_model_test` (new in 0002): passes with 0001 + 0002.

Status at the pin (onnxsim master `21f95fd1`, which `scripts/setup-onnxsim.sh` fetches by commit; the sdist and `scripts/onnxsim/patches/`
are no longer used): 0001 is upstream as commit `60b3e4e0` ("GraphBuilder: configurable floating-point element type for constants and
masks") and is in the history of the pin, so our build applies no patch. 0002 is not upstream; our shim `scripts/onnxsim/nfc_onnxsim.cpp`
does the same job in our tree. No onnxsim source is kept in the repository.

| Patch | Applied by our build | Problem | Covered by |
| --- | --- | --- | --- |
| `0001-graph-builder-float-type.patch` | no: upstream as `60b3e4e0`, in the pin | The C++ `GraphBuilder` builds every floating-point initializer in float32 and every mask as `Cast(..., to=FLOAT)`. A gradient is appended to the forward graph, so for a float64 forward the rules emit `Mul(g_float64, mask_float32)`, which ONNX rejects. Also, the mean rule's `1/N` is `float(1/N)`, so after widening to double a float64 gradient of `ReduceMean` is off by up to 2e-8 relative (measured: 6.2e-9 to 2.0e-8 on `mean-all`, `mean-keep`, `var`, `stddev` of our finite-difference suite; 4e-17 once fixed). | `graph_grad_test.cpp::TheFloatTypeOfTheBuilderReachesEveryConstantAndMask` (new): with `SetFloatType(DOUBLE)` every float initializer is DOUBLE, every mask `Cast` goes to DOUBLE, the mean's `1/N` is the double `1/3`; the default stays FLOAT; INT32 is refused. `qat_graph_builder_test` and the parity-sensitive naming are unchanged (same counter sequence). |
| `0002-graph-grad-model-and-c-abi.patch` | no (proposal; our shim `scripts/onnxsim/nfc_onnxsim.cpp` does the same and also lives in our tree) | There is no entry point that differentiates a *model*: `BuildBackward` needs the caller to pick the slice, extract static shapes, seed the loss, give targets the loss does not reach a zero, inline the model-local functions of the templated rules (see below) and keep the names unique, and there is no C ABI or installable library, so a consumer outside the Python/WASM bindings (here a program that dlopens it) rebuilds all that and must build the `onnx` + protobuf closure itself. 0002 adds `BuildGradientModel(ModelProto, loss, wrt, prefix)` and an `extern "C"` wrapper (`onnxsim_gradient_model`, `onnxsim_free`; no exception crosses it) and registers the new test in `CMakeLists.txt`. Depends on 0001 for float64. | `graph_grad_model_test.cpp` (new): one output per wrt with the shape/type of the wrt, prefixed names, zero gradient for an unreached wrt, float64 in/float64 out, the seed for loss == wrt, an unsupported operator off the path is ignored, on the path is `UnsupportedOpError`, bad loss/wrt are `invalid_argument`, the C ABI's three statuses. **Not built with their CMake** (the `CMakeLists.txt` hunk is unverified). |

## Gaps without a patch (evidence and what we did)

1. **Inlining the templated rules into a model whose opset is not 17.** `GraphBuilder::Call` registers functions written for opset 17;
   `MakeStepGraph` pins the step graph to opset 17 so `InlineLocalFunctions` works there. Appending the backward pass to a forward model of
   opset 18 (what `hir::Graph::to_onnx` writes) and inlining fails: `InlineLocalFunctions(model)` leaves the calls and shape inference
   stops with `No opset import for domain onnxsim.grad optype GradMul`; with `convert_version=true` it asserts in `inliner.cc:418 GetType`.
   Workaround in our shim: inline in a separate opset-17 model that declares the forward values it reads as inputs. 0002 contains that logic;
   a cleaner upstream fix would be a documented `InlineBackward(...)` helper or an inliner that accepts the lower function opset.
2. **Rule coverage differs from what a graph of a numpy-like front end needs.** At 0.8.1 the C++ rule table (`SupportedOps()`) was
   Add AveragePool BatchNormalization Clip Conv Div Erf Exp Gather Gemm Identity InstanceNormalization LayerNormalization Log MatMul
   MaxPool Mul Neg ReduceMean ReduceSum Relu Reshape Sigmoid Softmax Sqrt Sub Tanh Transpose, and `Where Slice Concat Pad Expand Squeeze
   Unsqueeze` existed only in the Python package. At the pin (`21f95fd1`) the C++ `Rules()` table also has `Abs Cast Concat LogSoftmax Max
   Min Pad ReduceMax ReduceMin Slice Squeeze Unsqueeze Where Expand`; `Slice` refuses non-positive steps. Still without a rule in either:
   `Sin Cos` and comparisons; a 1-D `MatMul` operand is refused (`MatMul with a 1-D operand is not differentiated here`); `Cast` refuses the
   casts its rule does not accept; the bounds of `Clip` get no gradient (we get a zero because the target is unreached). Evidence:
   `tests/uop/test_grad.cpp::unsupported` checks the operators that stay refused, each with the library's message; the native test-suite's
   finite-difference models are not all differentiable (see `docs/notes/uop-autodiff.md`). What we did: nothing local; the refused operators
   stay refused and the error carries the library's message (the Python fallback refuses the same set so both paths agree). Each further rule
   would be its own upstream change with a Python rule, a C++ port emitting the same nodes (their parity test), a finite-difference test in
   `tests/test_graph_grad.py` and an entry in `qat_parity_fixtures.txt`; we did not prepare them.
3. **`BuildBackward` refuses the whole slice for one node without a rule**, also when no gradient reaches that node (documented in `graph_grad.h`).
   Our shim restricts the slice to nodes that depend on a wrt, so operators off the path are not reached; no change proposed.
4. **The wheel ships no headers or static library**, and there is no CMake install/export target for `graph_grad`; the C++ sources are built from onnxsim's git tree at the pinned commit (fetched by hash; at 0.8.1 they came from the sdist)
   (we build `third_party/onnx` + `graph_grad.cpp` + `qat_graph_builder.cpp` with our own 20-line CMake, `scripts/onnxsim/CMakeLists.txt`). 0002 only
   adds the entry point; an `install(TARGETS ...)` and a `find_package(onnxsim)` config for the library would be the next step, not attempted.
5. **No Python counterpart of 0001**: `qat_graph.GraphBuilder.const` and `greater_mask` are float32-only too. The Python rules would need the same
   `float_dtype` option for float64 models; our Python fallback converts the emitted float32 constants and masks itself (`scripts/onnx_grad.py: to_double`).
