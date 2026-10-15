# Array API coverage: the numpy-style frontend

`lib/uop/nfcuop_np.hpp` (`nfcuop::np`) against the Python Array API standard (https://data-apis.org/array-api/latest/).

**Where the function list comes from.** The standard's index could not be fetched here: WebFetch failed to resolve data-apis.org, and a curl through the agent proxy was refused with 403. The list below is written from memory of the standard's sections (the 2024.12 revision as far as I know it), so it may miss a function added later, or use a name slightly different from the standard's. Three rows are less certain: `cumulative_prod` and `take_along_axis` (I believe both came with 2024.12), and `diff`, which is left out because I could not confirm it is in the standard.

**This is not a conformance claim.** The tests are the cases in `tests/uop/test_np.cpp` (values worked out by hand, and the errors) and in `tests/uop/np_compat.cpp` (compared with numpy). The standard's own test suite (array-api-tests) was not run.

Status: **has** (the function exists and does what the standard says for the dtypes the frontend has); **partial** (exists with a restriction the note states); **lacks** (not in the frontend; the note says what it needs); **not supported** (cannot be done in this design: a data-dependent output shape, or a protocol this library does not implement); **n/a** (needs complex dtypes, devices, or C++ syntax that does not exist). *On main* is the state before this change, *now* the state after it. Member functions count as has.

The *on main* column is origin/main at the base of this change (1f17d7c). The elementwise rows had said `lacks` for functions that main already has (`acos` to `tan`, `atan2`, `expm1`, `log1p`, `log2`, `log10`, `logaddexp`, `round`, the shifts), and they are corrected here. This change adds only the `<<` and `>>` operators, so the two columns differ only in the `<< >>` row. The statuses were checked against the declarations in `lib/uop/nfcuop_np.hpp` and the ONNX refusals in `lib/uop/nfcuop_hir.hpp`, not against the standard.

## Counts

Standard functions: 124 rows. 4 are n/a (complex dtypes, devices, the namespace object), so 120 are in scope.

| | on main | now |
|---|---|---|
| has | 95 | 95 |
| partial | 19 | 19 |
| lacks | 0 | 0 |
| not supported | 6 | 6 |
| n/a | 4 | 4 |
| total | 124 | 124 |

Operators and attributes: 25 rows, now has 12, partial 6, lacks 0, not supported 3, n/a 4 (on main: has 11, partial 6, lacks 1, not supported 3, n/a 4).

## Functions

| standard function | group | on main | now | frontend | note |
|---|---|---|---|---|---|
| arange | creation | has | has | Session::arange(n); arange(start, stop, step) |  |
| asarray | creation | partial | partial | asarray(Tensor), asarray(Session&, Array); Session::array, array2d, from | nested lists up to 2-D; no copy argument |
| empty | creation | has | has | Session::empty | values are zeros (the standard leaves them unspecified) |
| empty_like | creation | has | has | empty_like | zeros |
| eye | creation | has | has | Session::eye(n), Session::eye(rows, cols, k) |  |
| from_dlpack | creation | not supported | not supported | - | no DLPack buffer protocol |
| full | creation | has | has | Session::full |  |
| full_like | creation | has | has | full_like |  |
| linspace | creation | partial | partial | Session::linspace(start, stop, num, dtype, endpoint) | num = 0 would be empty: not supported (no empty tensors) |
| meshgrid | creation | has | has | meshgrid(inputs, xy) | one-dimensional inputs; indexing xy or ij |
| ones | creation | has | has | Session::ones |  |
| ones_like | creation | has | has | ones_like |  |
| tril | creation | has | has | tril(a, k) | the last two axes, at least two dimensions |
| triu | creation | has | has | triu(a, k) | the last two axes, at least two dimensions |
| zeros | creation | has | has | Session::zeros |  |
| zeros_like | creation | has | has | zeros_like |  |
| astype | data types | has | has | Tensor::astype | no copy argument: tensors are never changed in place |
| can_cast | data types | partial | partial | can_cast(from, to) | numpy's safe-casting rule over the five dtypes; the standard's table is not checked here |
| finfo | data types | partial | partial | finfo(dtype) | float32 and float64 only (no float16 or bfloat16) |
| iinfo | data types | partial | partial | iinfo(dtype) | int32 and int64 only (no unsigned types) |
| isdtype | data types | partial | partial | isdtype(dtype, kind) | kinds over the five dtypes; unsigned and complex are always false |
| result_type | data types | partial | partial | result_type(dtype, dtype); result_type(tensors) | no weak Python-scalar form (the operators have it) |
| abs | elementwise | has | has | Tensor::abs, abs |  |
| acos | elementwise | has | has | Tensor::acos, acos | ONNX operator |
| acosh | elementwise | has | has | Tensor::acosh, acosh | ONNX operator |
| add | elementwise | has | has | add (and operator+) | operator existed on main |
| asin | elementwise | has | has | Tensor::asin, asin | ONNX operator |
| asinh | elementwise | has | has | Tensor::asinh, asinh | ONNX operator |
| atan | elementwise | has | has | Tensor::atan, atan | ONNX operator |
| atan2 | elementwise | has | has | atan2(y, x) | computed; not an ONNX operator here, so to_onnx refuses it |
| atanh | elementwise | has | has | Tensor::atanh, atanh | ONNX operator |
| bitwise_and | elementwise | has | has | bitwise_and (and operator&) |  |
| bitwise_left_shift | elementwise | has | has | bitwise_left_shift(a, b) | integers only; not an ONNX operator here, so to_onnx refuses it |
| bitwise_invert | elementwise | has | has | bitwise_invert, operator~ | logical not for bool, -x - 1 for integers |
| bitwise_or | elementwise | has | has | bitwise_or (and operator\|) |  |
| bitwise_right_shift | elementwise | has | has | bitwise_right_shift(a, b) | integers only; not an ONNX operator here, so to_onnx refuses it |
| bitwise_xor | elementwise | has | has | bitwise_xor (and operator^) |  |
| ceil | elementwise | has | has | Tensor::ceil | member |
| conj | elementwise | n/a | n/a | - | complex dtypes only |
| cos | elementwise | has | has | Tensor::cos | member |
| cosh | elementwise | has | has | Tensor::cosh, cosh | ONNX operator |
| divide | elementwise | has | has | divide (and operator/) |  |
| equal | elementwise | has | has | equal (and operator==) |  |
| exp | elementwise | has | has | Tensor::exp, exp |  |
| expm1 | elementwise | has | has | Tensor::expm1, expm1 | computed (libm); not an ONNX operator here, so to_onnx refuses it |
| floor | elementwise | has | has | Tensor::floor | member; bool gives float (numpy's float16 is not here) |
| floor_divide | elementwise | partial | partial | floor_divide | integers only; the standard also wants floats |
| greater | elementwise | has | has | greater (and operator>) |  |
| greater_equal | elementwise | has | has | greater_equal (and operator>=) |  |
| imag | elementwise | n/a | n/a | - | complex dtypes only |
| isfinite | elementwise | has | has | isfinite | not NaN and not infinite |
| isinf | elementwise | has | has | Tensor::isinf | member |
| isnan | elementwise | has | has | Tensor::isnan | member |
| less | elementwise | has | has | less (and operator<) |  |
| less_equal | elementwise | has | has | less_equal (and operator<=) |  |
| log | elementwise | has | has | Tensor::log, log |  |
| log1p | elementwise | has | has | Tensor::log1p, log1p | computed (libm); not an ONNX operator here, so to_onnx refuses it |
| log2 | elementwise | has | has | Tensor::log2, log2 | computed (libm); not an ONNX operator here, so to_onnx refuses it |
| log10 | elementwise | has | has | Tensor::log10, log10 | computed (libm); not an ONNX operator here, so to_onnx refuses it |
| logaddexp | elementwise | has | has | logaddexp(a, b) | built from Log1p, so to_onnx refuses it |
| logical_and | elementwise | has | has | logical_and | bool operands only, as the standard |
| logical_not | elementwise | has | has | logical_not |  |
| logical_or | elementwise | has | has | logical_or | bool operands only |
| logical_xor | elementwise | has | has | logical_xor | bool operands only |
| multiply | elementwise | has | has | multiply (and operator*) |  |
| negative | elementwise | has | has | negative (and unary operator-) |  |
| not_equal | elementwise | has | has | not_equal (and operator!=) |  |
| positive | elementwise | has | has | positive (and unary operator+) | not for bool |
| pow | elementwise | has | has | pow(a, b) and pow(a, scalar) | not correctly rounded for floats (docs/notes/uop.md) |
| real | elementwise | n/a | n/a | - | complex dtypes only |
| remainder | elementwise | partial | partial | remainder, operator% | integers only; the standard also wants floats |
| round | elementwise | has | has | Tensor::round, round | ONNX operator; ties to even; an integer tensor is unchanged |
| sign | elementwise | partial | partial | sign | -0 gives +0; NaN stays NaN; not for bool |
| sin | elementwise | has | has | Tensor::sin | member |
| sinh | elementwise | has | has | Tensor::sinh, sinh | ONNX operator |
| square | elementwise | has | has | Tensor::square, square | member |
| sqrt | elementwise | has | has | Tensor::sqrt, sqrt |  |
| subtract | elementwise | has | has | subtract (and operator-) |  |
| tan | elementwise | has | has | Tensor::tan, tan | ONNX operator |
| tanh | elementwise | has | has | Tensor::tanh, tanh |  |
| trunc | elementwise | has | has | trunc | toward zero; not for bool |
| take | indexing | has | has | take(a, indices, axis) | axis None flattens (the standard wants an axis) |
| take_along_axis | indexing | has | has | take_along_axis | negative indices count from the end; the flat gather |
| matmul | linear algebra | has | has | matmul, dot |  |
| matrix_transpose | linear algebra | has | has | matrix_transpose | main had swapaxes only |
| tensordot | linear algebra | has | has | tensordot(a, b, n), tensordot(a, b, axes_a, axes_b) | through einsum |
| vecdot | linear algebra | has | has | vecdot(a, b, axis) | real values (no conjugate); bool is an error |
| broadcast_arrays | manipulation | has | has | broadcast_arrays |  |
| broadcast_to | manipulation | has | has | Tensor::broadcast_to |  |
| concat | manipulation | has | has | concat (and concatenate) | main had concatenate only |
| expand_dims | manipulation | partial | partial | Tensor::expand_dims(axis) | one axis; the standard takes a tuple |
| flip | manipulation | partial | partial | Tensor::flip(axis) | one axis; the standard's default (all axes) is not here |
| moveaxis | manipulation | has | has | moveaxis |  |
| permute_dims | manipulation | has | has | permute_dims, Tensor::transpose(perm) | main had transpose(perm) |
| repeat | manipulation | partial | partial | repeat(a, count, axis) | integer count only (no per-element counts) |
| reshape | manipulation | has | has | Tensor::reshape | one -1 dimension |
| roll | manipulation | has | has | roll(a, shift, axis), roll(a, shifts, axes) | axis None rolls the flattened array |
| squeeze | manipulation | partial | partial | Tensor::squeeze(axis) | one axis or all; the standard takes a tuple |
| stack | manipulation | has | has | stack |  |
| tile | manipulation | has | has | tile | no repetition of 0 (no empty tensors) |
| unstack | manipulation | has | has | unstack |  |
| argmax | searching | has | has | Tensor::argmax | int32 by default |
| argmin | searching | has | has | Tensor::argmin | int32 by default |
| nonzero | searching | not supported | not supported | - | data-dependent output shape (see below) |
| where | searching | has | has | where(cond, a, b) | the one-argument form is nonzero: not supported |
| searchsorted | searching | partial | partial | searchsorted(sorted, values, right) | no sorter argument; the input must be sorted; NaN last |
| unique_all | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_counts | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_inverse | set | not supported | not supported | - | data-dependent output shape (see below) |
| unique_values | set | not supported | not supported | - | data-dependent output shape (see below) |
| argsort | sorting | has | has | argsort(a, axis, descending) | always stable (the standard allows that); default int indices |
| sort | sorting | has | has | sort(a, axis, descending) | always stable; NaN last (first when descending) |
| cumulative_prod | statistical | partial | partial | cumulative_prod, cumprod | no dtype argument (astype first) |
| cumulative_sum | statistical | partial | partial | cumulative_sum; Tensor::cumsum | include_initial now; no dtype argument (astype first) |
| max | statistical | has | has | Tensor::max |  |
| mean | statistical | has | has | Tensor::mean |  |
| min | statistical | has | has | Tensor::min |  |
| prod | statistical | partial | partial | Tensor::prod | no dtype argument (astype first) |
| std | statistical | has | has | Tensor::stddev(axes, keepdims, correction) | correction; the main name is stddev |
| sum | statistical | partial | partial | Tensor::sum | no dtype argument (astype first) |
| var | statistical | has | has | Tensor::var(axes, keepdims, correction) | correction now |
| all | utility | has | has | all(a, axes, keepdims) |  |
| any | utility | has | has | any(a, axes, keepdims) |  |
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
| << >> | lacks | has | operator<<, operator>> | integers only, as bitwise_left_shift and bitwise_right_shift; not an ONNX operator here, so to_onnx refuses it |
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

Complete for the standard's signature now (partial before the earlier change): `eye`, `add`, `bitwise_and`, `bitwise_or`, `bitwise_xor`, `divide`, `equal`, `greater`, `greater_equal`, `less`, `less_equal`, `multiply`, `negative`, `not_equal`, `subtract`, `matrix_transpose`, `concat`, `permute_dims`, `std`, `var`.

Added as a further argument or a stricter form, still partial: `can_cast`, `finfo`, `iinfo`, `isdtype`, `result_type`, `sign`, `repeat`, `searchsorted`, `cumulative_prod`.

Not in ONNX, so not exportable: `expm1`, `log1p`, `log2`, `log10`, `logaddexp`, `atan2`, and the shifts (see the section below); they are in the frontend and computed. The trigonometric and hyperbolic functions and `round` are in the frontend with ONNX operators.

## Not supported: data-dependent output shapes

`nonzero`, `unique_all`, `unique_counts`, `unique_inverse` and `unique_values` have output shapes that depend on the values. Every tensor in this design has a static shape known when the graph is built: the Tensor carries it, the ONNX export records it, and the lowering to UOps and the C backend need it. Supporting these needs a dynamic dimension (a size bound with a runtime count, as ONNX's NonZero and Unique give a runtime shape) in hir shape inference, the reference interpreter, the UOp lowering and the C renderer. That is a design change, so no half version was added. `where(cond)` with one argument is nonzero, so it is not supported either.

`from_dlpack` and `__dlpack__` need the DLPack buffer protocol, which this library does not implement.

**Sorting is not data-dependent.** `sort` and `argsort` have the same shape as their input, so they are supported: the rank of each element is the number of elements before it in the order (computed with comparisons), and the sorted values are a gather of the input by that order. Their cost is quadratic in the length of the sorted axis, as `cumsum` already is in this frontend.

## Lacks: what the IR would need

Every function that the table lists as `has` or `partial` is in the frontend. The ones that are not ONNX operators (`expm1`, `log1p`, `log2`, `log10`, `atan2`, `logaddexp`, `bitwise_left_shift`, `bitwise_right_shift`, and the `<<` and `>>` operators built on the shifts) compute and lower, but `to_onnx` refuses a graph that uses one, because `hir` has no ONNX operator for them (`is_onnx_operator` in `nfcuop_hir.hpp`). Exporting them would need either a composition that loses accuracy for small or exact arguments (`exp(x) - 1`, `log(x) / log(2)`), or a non-standard operator. For the signed shifts, ONNX's BitShift is, as far as I know, defined for unsigned integers only; I did not verify this.

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

- `tests/uop/test_np.cpp`: `array_api_functions()` checks each added function with values worked out by hand from the inputs, and the errors each one documents. The shifts and their `<<`/`>>` operators are checked next to the other shift checks in `elementwise_functions()`. test_np has 559 checks in the host build with `-fsanitize=address,undefined` (`UOP_HOST=1`).
- `tests/uop/np_compat.cpp` / `np_compat.py`: 45 new expressions (sorting, searching, triangles, grids, rolls, cumulative functions, einsum and tensordot, the statistics with a correction, and more), evaluated by the interpreter and the C backend (which must agree bit for bit) and by numpy. The 121 existing expressions are unchanged. The new ones with an int64 or float64 result in numpy (argsort, searchsorted, count_nonzero, linspace with endpoint=False, eye) are in the list of documented dtype differences, which is now 22 with the 15 existing ones.

The ORT and tinygrad back ends were run on 18 of the new expressions in a scratch program (not committed) and agreed with the interpreter; they are not in the test programs. What is not verified here: the standard's own test suite, and any function outside the list above.

`tests/uop/test_grad` fails on this machine both before and after this change (the onnxsim library aborts with terminate() in the exception path); the failure reproduces from an unmodified checkout, so it is not caused by this change.
