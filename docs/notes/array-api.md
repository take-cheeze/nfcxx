# Array API coverage: the numpy-style frontend

`lib/uop/nfcuop_np.hpp` (`nfcuop::np`) against the Python Array API standard (https://data-apis.org/array-api/latest/).

**Where the function list comes from.** The standard's index could not be fetched here: WebFetch failed to resolve data-apis.org, and a curl through the agent proxy was refused with 403. The list below is written from memory of the standard's sections (the 2024.12 revision as far as I know it), so it may miss a function added later, or use a name slightly different from the standard's. Three rows are less certain: `cumulative_prod` and `take_along_axis` (I believe both came with 2024.12), and `diff`, which is left out because I could not confirm it is in the standard.

**This is not a conformance claim.** The tests are the cases in `tests/uop/test_np.cpp` (values worked out by hand, and the errors) and in `tests/uop/np_compat.cpp` (compared with numpy). The standard's own test suite (array-api-tests) was not run.

Status: **has** (the function exists and does what the standard says for the dtypes the frontend has); **partial** (exists with a restriction the note states); **lacks** (not in the frontend; the note says what it needs); **not supported** (cannot be done in this design: a data-dependent output shape, or a protocol this library does not implement); **n/a** (needs complex dtypes, devices, or C++ syntax that does not exist). *On main* is the state before this change, *now* the state after it. Member functions count as has.

## Counts

Standard functions: 124 rows. 4 are n/a (complex dtypes, devices, the namespace object), so 120 are in scope.

| | on main | now |
|---|---|---|
| has | 31 | 77 |
| partial | 30 | 19 |
| lacks | 53 | 18 |
| not supported | 6 | 6 |
| n/a | 4 | 4 |
| total | 124 | 124 |


Operators and attributes: 25 rows, now has 11, partial 6, lacks 1, not supported 3, n/a 4 (on main: has 9, partial 5, lacks 4, not supported 3, n/a 4).

## Functions

| standard function | group | on main | now | frontend | note |
|---|---|---|---|---|---|
| arange | creation | has | has | Session::arange(n); arange(start, stop, step) |  |
| asarray | creation | partial | partial | asarray(Tensor), asarray(Session&, Array); Session::array, array2d, from | nested lists up to 2-D; no copy argument |
| empty | creation | lacks | has | Session::empty | values are zeros (the standard leaves them unspecified) |
| empty_like | creation | lacks | has | empty_like | zeros |
| eye | creation | partial | has | Session::eye(n), Session::eye(rows, cols, k) |  |
| from_dlpack | creation | not supported | not supported | - | no DLPack buffer protocol |
| full | creation | has | has | Session::full |  |
| full_like | creation | lacks | has | full_like |  |
| linspace | creation | partial | partial | Session::linspace(start, stop, num, dtype, endpoint) | num = 0 would be empty: not supported (no empty tensors) |
| meshgrid | creation | lacks | has | meshgrid(inputs, xy) | one-dimensional inputs; indexing xy or ij |
| ones | creation | has | has | Session::ones |  |
| ones_like | creation | lacks | has | ones_like |  |
| tril | creation | lacks | has | tril(a, k) | the last two axes, at least two dimensions |
| triu | creation | lacks | has | triu(a, k) | the last two axes, at least two dimensions |
| zeros | creation | has | has | Session::zeros |  |
| zeros_like | creation | lacks | has | zeros_like |  |
| astype | data types | has | has | Tensor::astype | no copy argument: tensors are never changed in place |
| can_cast | data types | lacks | partial | can_cast(from, to) | numpy's safe-casting rule over the five dtypes; the standard's table is not checked here |
| finfo | data types | lacks | partial | finfo(dtype) | float32 and float64 only (no float16 or bfloat16) |
| iinfo | data types | lacks | partial | iinfo(dtype) | int32 and int64 only (no unsigned types) |
| isdtype | data types | lacks | partial | isdtype(dtype, kind) | kinds over the five dtypes; unsigned and complex are always false |
| result_type | data types | lacks | partial | result_type(dtype, dtype); result_type(tensors) | no weak Python-scalar form (the operators have it) |
| abs | elementwise | has | has | Tensor::abs, abs |  |
| acos | elementwise | lacks | lacks | - | needs an Acos op (ONNX has one; not in hir or ut) |
| acosh | elementwise | lacks | lacks | - | needs an Acosh op (ONNX has one; not in hir or ut) |
| add | elementwise | partial | has | add (and operator+) | operator existed on main |
| asin | elementwise | lacks | lacks | - | needs an Asin op (ONNX has one; not in hir or ut) |
| asinh | elementwise | lacks | lacks | - | needs an Asinh op (ONNX has one; not in hir or ut) |
| atan | elementwise | lacks | lacks | - | needs an Atan op (ONNX has one; not in hir or ut) |
| atan2 | elementwise | lacks | lacks | - | needs an Atan2 op (not verified whether ONNX has one) |
| atanh | elementwise | lacks | lacks | - | needs an Atanh op (ONNX has one; not in hir or ut) |
| bitwise_and | elementwise | partial | has | bitwise_and (and operator&) |  |
| bitwise_left_shift | elementwise | lacks | lacks | - | needs a shift op; x * 2^k would wrap for k at the top bit |
| bitwise_invert | elementwise | lacks | has | bitwise_invert, operator~ | logical not for bool, -x - 1 for integers |
| bitwise_or | elementwise | partial | has | bitwise_or (and operator|) |  |
| bitwise_right_shift | elementwise | lacks | lacks | - | needs a shift op (ONNX BitShift is unsigned-only, not verified) |
| bitwise_xor | elementwise | partial | has | bitwise_xor (and operator^) |  |
| ceil | elementwise | has | has | Tensor::ceil | member |
| conj | elementwise | n/a | n/a | - | complex dtypes only |
| cos | elementwise | has | has | Tensor::cos | member |
| cosh | elementwise | lacks | lacks | - | needs a Cosh op (ONNX has one; not in hir or ut) |
| divide | elementwise | partial | has | divide (and operator/) |  |
| equal | elementwise | partial | has | equal (and operator==) |  |
| exp | elementwise | has | has | Tensor::exp, exp |  |
| expm1 | elementwise | lacks | lacks | - | exp(x) - 1 loses accuracy for small x; needs an op |
| floor | elementwise | has | has | Tensor::floor | member; bool gives float (numpy's float16 is not here) |
| floor_divide | elementwise | partial | partial | floor_divide | integers only; the standard also wants floats |
| greater | elementwise | partial | has | greater (and operator>) |  |
| greater_equal | elementwise | partial | has | greater_equal (and operator>=) |  |
| imag | elementwise | n/a | n/a | - | complex dtypes only |
| isfinite | elementwise | lacks | has | isfinite | not NaN and not infinite |
| isinf | elementwise | has | has | Tensor::isinf | member |
| isnan | elementwise | has | has | Tensor::isnan | member |
| less | elementwise | partial | has | less (and operator<) |  |
| less_equal | elementwise | partial | has | less_equal (and operator<=) |  |
| log | elementwise | has | has | Tensor::log, log |  |
| log1p | elementwise | lacks | lacks | - | log(1 + x) loses accuracy for small x; needs an op |
| log2 | elementwise | lacks | lacks | - | needs an op (log(x) / log(2) is not exact) |
| log10 | elementwise | lacks | lacks | - | needs an op (log(x) / log(10) is not exact) |
| logaddexp | elementwise | lacks | lacks | - | needs an op: the composition loses the infinite cases |
| logical_and | elementwise | lacks | has | logical_and | bool operands only, as the standard |
| logical_not | elementwise | has | has | logical_not |  |
| logical_or | elementwise | lacks | has | logical_or | bool operands only |
| logical_xor | elementwise | lacks | has | logical_xor | bool operands only |
| multiply | elementwise | partial | has | multiply (and operator*) |  |
| negative | elementwise | partial | has | negative (and unary operator-) |  |
| not_equal | elementwise | partial | has | not_equal (and operator!=) |  |
| positive | elementwise | lacks | has | positive (and unary operator+) | not for bool |
| pow | elementwise | has | has | pow(a, b) and pow(a, scalar) | not correctly rounded for floats (docs/notes/uop.md) |
| real | elementwise | n/a | n/a | - | complex dtypes only |
| remainder | elementwise | partial | partial | remainder, operator% | integers only; the standard also wants floats |
| round | elementwise | lacks | lacks | - | needs a Round op (numpy rounds half to even) |
| sign | elementwise | lacks | partial | sign | -0 gives +0; NaN stays NaN; not for bool |
| sin | elementwise | has | has | Tensor::sin | member |
| sinh | elementwise | lacks | lacks | - | needs a Sinh op (ONNX has one; not in hir or ut) |
| square | elementwise | has | has | Tensor::square, square | member |
| sqrt | elementwise | has | has | Tensor::sqrt, sqrt |  |
| subtract | elementwise | partial | has | subtract (and operator-) |  |
| tan | elementwise | lacks | lacks | - | needs a Tan op (ONNX has one; not in hir or ut) |
| tanh | elementwise | has | has | Tensor::tanh, tanh |  |
| trunc | elementwise | lacks | has | trunc | toward zero; not for bool |
| take | indexing | has | has | take(a, indices, axis) | axis None flattens (the standard wants an axis) |
| take_along_axis | indexing | lacks | has | take_along_axis | negative indices count from the end; the flat gather |
| matmul | linear algebra | has | has | matmul, dot |  |
| matrix_transpose | linear algebra | partial | has | matrix_transpose | main had swapaxes only |
| tensordot | linear algebra | lacks | has | tensordot(a, b, n), tensordot(a, b, axes_a, axes_b) | through einsum |
| vecdot | linear algebra | lacks | has | vecdot(a, b, axis) | real values (no conjugate); bool is an error |
| broadcast_arrays | manipulation | lacks | has | broadcast_arrays |  |
| broadcast_to | manipulation | has | has | Tensor::broadcast_to |  |
| concat | manipulation | partial | has | concat (and concatenate) | main had concatenate only |
| expand_dims | manipulation | partial | partial | Tensor::expand_dims(axis) | one axis; the standard takes a tuple |
| flip | manipulation | partial | partial | Tensor::flip(axis) | one axis; the standard's default (all axes) is not here |
| moveaxis | manipulation | lacks | has | moveaxis |  |
| permute_dims | manipulation | partial | has | permute_dims, Tensor::transpose(perm) | main had transpose(perm) |
| repeat | manipulation | lacks | partial | repeat(a, count, axis) | integer count only (no per-element counts) |
| reshape | manipulation | has | has | Tensor::reshape | one -1 dimension |
| roll | manipulation | lacks | has | roll(a, shift, axis), roll(a, shifts, axes) | axis None rolls the flattened array |
| squeeze | manipulation | partial | partial | Tensor::squeeze(axis) | one axis or all; the standard takes a tuple |
| stack | manipulation | has | has | stack |  |
| tile | manipulation | has | has | tile | no repetition of 0 (no empty tensors) |
| unstack | manipulation | lacks | has | unstack |  |
| argmax | searching | has | has | Tensor::argmax | int32 by default |
| argmin | searching | has | has | Tensor::argmin | int32 by default |
| nonzero | searching | not supported | not supported | - | data-dependent output shape (see below) |
| where | searching | has | has | where(cond, a, b) | the one-argument form is nonzero: not supported |
| searchsorted | searching | lacks | partial | searchsorted(sorted, values, right) | no sorter argument; the input must be sorted; NaN last |
| unique_all | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_counts | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_inverse | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_values | set | not supported | not supported | - | data-dependent output shape (see below) |
| argsort | sorting | lacks | has | argsort(a, axis, descending) | always stable (the standard allows that); default int indices |
| sort | sorting | lacks | has | sort(a, axis, descending) | always stable; NaN last (first when descending) |
| cumulative_prod | statistical | lacks | partial | cumulative_prod, cumprod | no dtype argument (astype first) |
| cumulative_sum | statistical | partial | partial | cumulative_sum; Tensor::cumsum | include_initial now; no dtype argument (astype first) |
| max | statistical | has | has | Tensor::max |  |
| mean | statistical | has | has | Tensor::mean |  |
| min | statistical | has | has | Tensor::min |  |
| prod | statistical | partial | partial | Tensor::prod | no dtype argument (astype first) |
| std | statistical | partial | has | Tensor::stddev(axes, keepdims, correction) | correction; the main name is stddev |
| sum | statistical | partial | partial | Tensor::sum | no dtype argument (astype first) |
| var | statistical | partial | has | Tensor::var(axes, keepdims, correction) | correction now |
| all | utility | lacks | has | all(a, axes, keepdims) |  |
| any | utility | lacks | has | any(a, axes, keepdims) |  |
| __array_namespace_info__ and its functions | inspection | n/a | n/a | - | no namespace objects, devices or capabilities here |

## Operators and attributes

| operator or attribute | on main | now | frontend | note |
|---|---|---|---|---|
| + (binary) | has | has | operator+ |  |
| - (binary) | has | has | operator- |  |
| - (unary) | has | has | Tensor::operator- |  |
| + (unary) | lacks | has | operator+ (positive) |  |
| * | has | has | operator* |  |
| / | has | has | operator/ (true division) |  |
| // | partial | partial | floor_divide | integers only |
| % | partial | partial | operator% | integers only |
| ** | n/a | n/a | pow(a, b) | C++ has no ** operator |
| @ | n/a | n/a | matmul(a, b) | C++ has no @ operator |
| < <= > >= == != | has | has | operators | elementwise, returning bool tensors |
| `&`, `\|`, `^` | has | has | operators | integers and bool |
| ~ | lacks | has | operator~ |  |
| << >> | lacks | lacks | - | needs a shift op |
| in-place forms (+=, ...) | not supported | not supported | - | no in-place updates (by design: docs/notes/uop.md) |
| indexing (__getitem__) | partial | partial | slice, at, flip | no fancy, boolean, ellipsis or None index |
| __setitem__ | not supported | not supported | - | no in-place updates |
| __len__ | partial | partial | shape()[0] | no Python protocol |
| __bool__, __int__, __float__, __index__ | partial | partial | item() | single-element tensors only |
| attribute dtype, ndim, shape, size | has | has | dtype(), ndim(), shape(), size() |  |
| attribute T | has | has | T() | reverses all axes, for any ndim |
| attribute mT | lacks | partial | matrix_transpose | as a function, not an attribute |
| attribute device, to_device | n/a | n/a | - | no devices |
| __dlpack__, __dlpack_device__ | not supported | not supported | - | no DLPack |
| __array_namespace__, __array_device__ | n/a | n/a | - | no namespace or device objects |

## Constants and dtypes

| operator or attribute | on main | now | frontend | note |
|---|---|---|---|---|
| e, inf, nan, pi | lacks | lacks | - | not added: C++ has std::numbers, INFINITY and NAN, and namespace-level pi or e would collide with user names |
| newaxis | not supported | not supported | expand_dims | Python index syntax; not in the frontend |
| dtype objects | partial | partial | bool, int32, int64, float32, float64 | no unsigned, small-int, float16, bfloat16 or complex |

## Functions not in the standard that the frontend has

Not in the standard, and kept because they belong to the numpy-style API: `einsum`, `count_nonzero`, `copy` (the same tensor, since tensors are never changed in place), `cumprod` (= `cumulative_prod` without `include_initial`), `cumsum` (= `cumulative_sum` without `include_initial`), `maximum`, `minimum`, `dot`, `concatenate`, `relu`, `softmax`, `grad`, `sigmoid`.

## Added in this change

New functions: `Session::empty`, `empty_like`, `full_like`, `meshgrid`, `ones_like`, `tril`, `triu`, `zeros_like`, `bitwise_invert`, `isfinite`, `logical_and`, `logical_or`, `logical_xor`, `positive`, `trunc`, `take_along_axis`, `tensordot`, `vecdot`, `broadcast_arrays`, `moveaxis`, `roll`, `unstack`, `argsort`, `sort`, `all`, `any`.

Partly on main and now complete for the standard's signature: `eye`, `add`, `bitwise_and`, `bitwise_or`, `bitwise_xor`, `divide`, `equal`, `greater`, `greater_equal`, `less`, `less_equal`, `multiply`, `negative`, `not_equal`, `subtract`, `matrix_transpose`, `concat`, `permute_dims`, `std`, `var`.

Added as a further argument or a stricter form, still partial: `can_cast`, `finfo`, `iinfo`, `isdtype`, `result_type`, `sign`, `repeat`, `searchsorted`, `cumulative_prod`.

Not added, and why: the trigonometric, hyperbolic and logarithmic functions, `round`, `logaddexp`, `atan2`, and the shifts (see the next section). Their IR ops are missing, and a composition would lose accuracy or the special values the standard specifies.

## Not supported: data-dependent output shapes

`nonzero`, `unique_all`, `unique_counts`, `unique_inverse` and `unique_values` have output shapes that depend on the values. Every tensor in this design has a static shape known when the graph is built: the Tensor carries it, the ONNX export records it, and the lowering to UOps and the C backend need it. Supporting these needs a dynamic dimension (a size bound with a runtime count, as ONNX's NonZero and Unique give a runtime shape) in hir shape inference, the reference interpreter, the UOp lowering and the C renderer. That is a design change, so no half version was added. `where(cond)` with one argument is nonzero, so it is not supported either.

`from_dlpack` and `__dlpack__` need the DLPack buffer protocol, which this library does not implement.

**Sorting is not data-dependent.** `sort` and `argsort` have the same shape as their input, so they are supported: the rank of each element is the number of elements before it in the order (computed with comparisons), and the sorted values are a gather of the input by that order. Their cost is quadratic in the length of the sorted axis, as `cumsum` already is in this frontend.

## Lacks: what the IR would need

Trigonometric and hyperbolic functions (`acos`, `acosh`, `asin`, `asinh`, `atan`, `atanh`, `cosh`, `sinh`, `tan`): ONNX has an operator for each, but hir and the UOp lowering do not have them (only Sqrt, Exp, Log, Sin, Cos, Tanh, Sigmoid, Erf, Floor and Ceil are there). Adding one means hir shape inference, the reference interpreter, the lowering, the C renderer and the gradient rule if it should differentiate.

`expm1`, `log1p`, `log2`, `log10`, `logaddexp`, `atan2`: no ONNX operator that I could confirm for all of them (`atan2` and `log1p`/`expm1` in particular are not verified). The compositions (`exp(x) - 1`, `log(x) / log(2)`) lose accuracy for small or exact arguments, so they are not added.

`round`: needs a Round operator (ONNX has one). numpy rounds half to even, which the operator would have to match.

`bitwise_left_shift`, `bitwise_right_shift`, and the `<<` and `>>` operators: no shift op in hir. ONNX's BitShift is, as far as I know, defined for unsigned integers only, so the signed shifts would need a new op. Multiplying by 2^k is not used: it wraps at the top bit.

Complex dtypes (`real`, `imag`, `conj`) and unsigned, small-integer, float16 and bfloat16 dtypes are not in the frontend's dtype set (bool, int32, int64, float32, float64).

## Differences from the standard, in what was added

- `sort` and `argsort` order -0 and +0 as equal (they keep their index order). NaN is last ascending and first descending. I did not check whether the standard requires -0 before +0.
- `searchsorted` does not take a `sorter`, and the input must be sorted; numpy's binary search gives other indices for unsorted input.
- `can_cast` is numpy's rule over the five dtypes, not a check of the standard's promotion table.
- `sign` maps -0 to +0. `trunc`, `sign` and the bitwise inversion reject bool where the standard does not define them.
- `empty` and `empty_like` return zeros (the standard leaves the values unspecified).
- `std`, `var` take `correction`; the statistical functions have no `dtype` argument (use `astype` first).
- The `einsum` and `tensordot` in this frontend form the full product of the operands before summing, so their memory is the product of all the index sizes. No ellipsis, and no index repeated within one operand (a diagonal).

## How it is checked

- `tests/uop/test_np.cpp`: `array_api_functions()` checks each added function with values worked out by hand from the inputs, and the errors each one documents. Before this change test_np had 322 checks; now 483.
- `tests/uop/np_compat.cpp` / `np_compat.py`: 45 new expressions (sorting, searching, triangles, grids, rolls, cumulative functions, einsum and tensordot, the statistics with a correction, and more), evaluated by the interpreter and the C backend (which must agree bit for bit) and by numpy. The 121 existing expressions are unchanged. The new ones with an int64 or float64 result in numpy (argsort, searchsorted, count_nonzero, linspace with endpoint=False, eye) are in the list of documented dtype differences, which is now 22 with the 15 existing ones.

The ORT and tinygrad back ends were run on 18 of the new expressions in a scratch program (not committed) and agreed with the interpreter; they are not in the test programs. What is not verified here: the standard's own test suite, and any function outside the list above.

`tests/uop/test_grad` fails on this machine both before and after this change (the onnxsim library aborts with terminate() in the exception path); the failure reproduces from an unmodified checkout, so it is not caused by this change.
