# nfcuop from scripts: the numpy-like API in Ruby, Lua, Python, JavaScript and Go

`lib/uop/nfcuop_poly.hpp/.cpp` (stage 5 of `uop.md`) exposes `nfcuop::np` (`nfcuop_np.hpp`) to the script languages of
`nfcpoly` (`poly.md`): a script builds tensor graphs, evaluates them (interpreter or C backend) and exports ONNX with the calls
the C++ API has. One function binds everything:

```cpp
nfcuop::np::Session session;                  // the Session and its tensors must outlive the scripts
nfcpoly::Context ctx;
nfcuop::poly::bind_numpy(ctx, session);       // the classes Tensor and NumPy, and the global `np` (a NumPy)
ctx.eval_void("python", "np.save_onnx('m.onnx', [['y', np.placeholder('x', [2, 2]) * 2 + 1]])");
```

The same model in the five languages (an excerpt of `tests/uop/test_poly.cpp`; every line makes the same calls in the same order as
the C++ model, which is why the graphs, and the ONNX bytes, are identical):

```python
x = np.placeholder('x', [4, 3]);  w1 = np.array([[...]]);  b1 = np.array([...])
h = np.relu(x @ w1 + b1);  prob = np.softmax(h @ w2 + b2)
cat = np.concatenate([prob[:, 0:1], logits * 0.5 - 1], 1);  red = prob.sum(0)
res = np.eval_all([prob, cat, red], [['x', [[1, 2, 3], ...]]])      # nested lists in and out
```
```ruby
h = np.relu(x.matmul(w1) + b1);  prob = np.softmax(h.matmul(w2) + b2);  cat = np.concatenate([prob[nil, 0...1], logits * 0.5 - 1], 1)
```
```lua
local h = np:relu(x:matmul(w1) + b1)    -- np:f(...) : the global np is an object, Lua passes it as the first argument
local cat = np:concatenate({prob:index(nil, '0:1'), logits * 0.5 - 1}, 1)
```
```js
const h = np.relu(x.matmul(w1).add(b1)); const cat = np.concatenate([prob.index(null, '0:1'), logits.mul(0.5).sub(1)], 1);
```
```go
h := np.Relu(x.Matmul(w1).Add(b1)); cat := np.Concatenate([]any{prob.Index(nil, "0:1"), logits.Mul(0.5).Sub(1)}, 1)
```

## What each language gets

| | Python | Ruby | Lua | JavaScript | Go |
| --- | --- | --- | --- | --- | --- |
| call | `np.zeros([2, 2])`, `t.sum(1)` | same | `np:zeros({2, 2})`, `t:sum(1)` (colon) | same as Python | `np.Zeros([]int{2, 2})`, `t.Sum(1)` (CamelCase of the snake_case name: `to_onnx` is `ToOnnx`, `and_` is `And`) |
| properties | `t.shape` `t.ndim` `t.size` `t.dtype` `t.T`; `np.default_float = "float64"` | same | same (`t.T`, `np.backend = "c"`) | same (accessors) | methods: `t.Shape()`, `t.T()`, `np.SetBackend("c")` |
| operators `+ - * / % & \| ^`, unary `-` | yes, numbers on either side (`2 - t`) | yes, numbers on the right only | yes, either side (`&` `\|` `~` for and, or, xor) | no | no |
| `//` (floor_divide), `@` (matmul) | yes, yes | no, no | `//` yes, `@` does not exist | no | no |
| `< > <= >= == !=` | yes; the result is a bool tensor (so `if t == u` is always true) | yes, same | **no**: Lua turns the result of `__lt`, `__le` and `__eq` into a boolean | no | no |
| `abs(t)`, `str(t)`, `repr(t)`, hash | yes | `to_s`, `inspect` | `tostring(t)` | `String(t)` | `t.Str()` |
| indexing | `t[1]`, `t[:, 1:3]`, `t[::-1, 0]` | `t[1]`, `t[nil, 1..2]` | `t:index(1, '1:3')` | `t.index(1, '1:3')` | `t.Index(1, "1:3")` |
| named methods | all | all | all | all | all |
| errors | `except Exception as e: str(e)` | `rescue => e; e.message` | `pcall`, `e.message` | `catch (e) { e.message }` | `recover()`, `nfc.ErrMessage(r)` |

Every language has the named forms (`add sub mul div mod floor_divide matmul lt gt le ge eq ne and_ or_ xor neg`), which are the
only form in JavaScript and Go and the fallback where an operator cannot exist.

## The API

`Tensor` (an `np::Tensor`, a handle into the Session's graph; the script classes copy it, which is cheap):

| | |
| --- | --- |
| properties | `shape` (a list), `ndim`, `size`, `dtype` (a name), `T` |
| binary, with a Tensor, a number or a nested list | `add sub mul div mod floor_divide matmul dot maximum minimum lt gt le ge eq ne and_ or_ xor` |
| unary | `neg abs sqrt exp log sin cos tanh sigmoid relu square reciprocal logical_not`, `softmax(axis=-1)`, `log_softmax(axis=-1)`, `clip(lo, hi)` |
| reductions `(axis=nil, keepdims=false)`; axis is an integer or a list | `sum mean max min var std` (`stddev`) |
| shape | `reshape(dims)` `transpose(perm)` `swapaxes(a, b)` `flatten` `ravel` `squeeze(axis)` `expand_dims(axis)` `broadcast_to(shape)` `astype(dtype)` `slice(axis, start, stop, step)` `at(index, axis=0)` `flip(axis=0)` `index(i, j, ...)`; `reshape` and `transpose` take a list or separate integers |
| realization | `numpy()` / `tolist()` (a nested list, ints for integer tensors, bools for bool), `values()` (flat), `item()`, `str()` (`"[[1., 2.], [3., 4.]]"`), `dump()`, `dump_uops()` |

`np` (a `NumPy`, an `np::Session`):

| | |
| --- | --- |
| creation | `array(data, dtype=nil)` (`array2d` is the same), `scalar(v, dtype)`, `zeros(shape, dtype)`, `ones`, `full(shape, v, dtype)`, `arange(stop)`, `arange(start, stop[, step])` (a dtype name may follow), `linspace(start, stop, num, dtype)`, `eye(n, dtype)`, `placeholder(name, shape, dtype)` |
| evaluation, export | `eval(t, feeds=nil)`, `eval_all(ts, feeds=nil)`, `to_onnx(outputs, graph_name=nil)` (the bytes), `save_onnx(path, outputs)` |
| functions | `where maximum minimum floor_divide remainder matmul dot logical_not concatenate(ts, axis=0) stack(ts, axis=0) softmax log_softmax clip abs sqrt exp log sin cos tanh sigmoid relu square reciprocal sum mean max min var std reshape transpose expand_dims squeeze flip broadcast_to` |
| configuration | read-write `default_float` (`"float32"`/`"float64"`), `default_int` (`"int32"`/`"int64"`), `backend` (`"interpreter"`/`"c"`), `cc`, `optimize`; read-only dtype names `float32 float64 int32 int64 bool_` |

Conventions, decided from the backends' limits:

- **dtypes** are names (`"float32"`, `"int32"`, ...; `np.float32` is the string), shapes an integer or a list of integers.
  `np.array(data)` makes `default_float`, like the C++ `Session::array` (numpy would infer int64 from `[1, 2]`; pass `"int32"`).
  Numbers next to tensors are weak scalars with the semantics of the C++ operator overloads: an integer takes the tensor's
  dtype, a float next to an integer tensor takes `default_float`, `bool` counts as an integer (`lift` in `nfcuop_np.hpp`).
  JavaScript has one number type and nfcpoly passes a whole number as an integer, so `t.mul(2.0)` is `t.mul(2)` there (the same
  for a float tensor, different next to an integer tensor).
- **nested lists** in (`array`, feeds, list operands such as `np.matmul(a_list, b_list)`) and out (`tolist`, `eval`): rectangular, at
  least one element per dimension, all numbers (bool, integer, float).
- **no keyword arguments**: `np.array(x, dtype="int32")` is a `TypeError` in Python (bound functions take positional arguments;
  the backends have no parameter names). Optional arguments are trailing, and `nil` fills a middle one.
- **feeds and outputs** are lists of pairs, because the neutral value model of nfcpoly has no dictionary: `np.eval(y, [["x", data],
  ["w", a_tensor]])`, `np.save_onnx(path, [["y", y]])`. The data of a feed is a nested list (it takes the dtype of the placeholder,
  which the `NumPy` object remembers by name) or a Tensor.
- **indexing**: an integer picks along the next axis and drops it, a slice keeps it, `nil` takes the whole axis; a slice is Python's
  slice object, a Ruby Range (`1..2`, `1...2`, `1..-1`), a text `"1:3"` / `"::-1"` / `":2"`, or a list `[start, stop, step]`. A
  slice that takes the whole axis adds no node, so `p[:, 0:1]` is the graph of `p.slice(1, 0, 1)`. No ellipsis, no newaxis, no
  boolean or integer-list indexing.
- **errors**: `nfcuop::Error` thrown by a call is, in the script, the language's host error (Python `HostError`, Ruby
  `NfcPoly::HostError`, JavaScript `NfcPoly::HostError`, Lua a table with `class` and `message`, Go `*nfc.HostError`) with the
  message of the C++ exception: `"np: cannot reshape ..."`. A script that does not rescue it gets it back from `Context::eval`
  as the very `nfcuop::Error`. Errors of the script's side (wrong argument count, `np: unsupported operand`, `np: unknown dtype ...`,
  `np: ragged nested list`) are `nfcuop::Error`s too or the language's own `TypeError`/`ArgumentError`.
- **lifetime**: a script's `Tensor` is a copy of an `np::Tensor` that points into the Session; `Value::as<np::Tensor>()` gives it to
  C++ and `Context::set("t", tensor)` gives a C++ tensor to every language (`test_poly.cpp`, "interop").

## How the operators reach the languages

`nfcpoly` had no way to register an operator, and no optional arguments (a bound function took exactly its arity), no computed
properties (a property was a data member) and no way to pass a host object held in a Go variable as a `Value`. Four small additions
(`poly.md`, "Optional arguments, computed properties and operators"; none changes an existing binding) close the gaps, and
`nfcuop_poly.cpp` registers each operator under its **Python special method name**, which each backend maps:

| registered method | Python | Ruby | Lua | JavaScript, Go |
| --- | --- | --- | --- | --- |
| `__add__ __sub__ __mul__ __truediv__ __mod__` | `+ - * / %` | same | `+ - * / %` | named methods only |
| `__radd__ __rsub__ __rmul__ __rtruediv__ __rmod__` | `2 + t` | (none: mruby's Integer and Float do not ask the other operand) | `2 + t` | |
| `__floordiv__` `__matmul__` | `//` `@` | none | `//`, none | |
| `__and__ __or__ __xor__` (+ reflected) | `& \| ^` | `& \| ^` | `& \| ~` | |
| `__neg__` `__abs__` | `-t` `abs(t)` | `-@` | `-t` | |
| `__lt__ __le__ __gt__ __ge__ __eq__ __ne__` | `< <= > >= == !=` (`5 > t` calls `t.__lt__(5)`) | same | none | |
| `__getitem__` | `t[k]` | `t[k]` | none | |
| `__str__` `__repr__` | `str` `repr` | `to_s` `inspect` | `tostring` | (`toString`, `str` are ordinary methods) |

The Go backend skips every method named `__x__` (their Go names would collide with `Add`, `Sub`, ...). The Python type also
defines `__hash__` by identity (a type with `__eq__` and no `__hash__` is unhashable), so tensors stay usable as dictionary keys.

## Tests

`tests/uop/test_poly.cpp`, built and run per language set by `tests/uop/run_poly.sh` (called by `tests/uop/run.sh`, so CI runs it
in the `nfcpoly` job on both nfcxx back ends). Everything runs once per language, with the script written in that language:

- **model**: an MLP with softmax, broadcasting arithmetic with scalars, slicing, concatenation, a reduction, integer arithmetic,
  a comparison and `where`, a transpose, built in the language and in C++. (a) The values are **equal bit for bit** to the C++
  API's (and, except in JavaScript, so are the element kinds: ints stay ints, bools stay bools), the dtypes, shapes, `ndim` and
  `size` too. (b) `np.save_onnx` writes bytes **identical** to `Session::to_onnx` of the C++ model, in every language (so also
  identical across the languages). The first language's file is also checked by `onnx_check.py` (onnx.checker, then onnxruntime
  against the interpreter).
- **operators** (Python, Ruby, Lua) and **named methods** (all five): 37 cases (28 with a named form), each compared with the C++ operator it stands for:
  arithmetic, floor division, comparisons, bitwise, unary minus, `@`, numbers on either side, an integer tensor with a float.
- **errors**: nine failing statements per language; the script catches the error and returns its message, which must equal
  the message of the C++ exception; the same statement uncaught must leave `eval` as an `nfcuop::Error` with that message (the seven whose message is the library's own).
- **dtypes**: the dtype of 16 constructors and operations (and the two defaults read back) under the default and the float64/int64 configuration set from the script
  equals the C++ `Session`'s; a bad configuration is an error.
- **backend**: `np.backend = "c"` from the script, a matmul-softmax-sum evaluated through generated C equals the interpreter bit for
  bit (skipped with a line when no C compiler is found: `$NFCUOP_CC` or `cc`).
- **data**: 45 expressions (reshape forms, `arange` forms, slicing, `index`, reductions with axis lists and keepdims, stack,
  concatenate, math, `where` and `maximum` with scalars, list operands) compared with the C++ results, with the kind of every
  element; feeds as lists and as Tensors; `eval_all`; `str`; a Tensor given to C++ and back; 1000 tensors made in a loop.
- **Python only**: indexing with ints, slices, steps, tuples; `abs`, `repr`, hashing; the keyword argument error. **Ruby only**: ranges
  and `[]`, `respond_to?`, and that `2 - t` is a `TypeError` and not a wrong answer.
- `tests/poly/ops.cpp` (run by `tests/poly/run.sh`) tests the three nfcpoly additions on a small class in every language: optional
  arguments (too few and too many arguments, `Value::call` from C++), computed properties (read, write, read only) and the
  operator methods.

### Running it here

```
UOP_HOST=1 tests/uop/run_poly.sh        # host g++, no nfcxx: the interpreters come from scripts/setup-poly-host.sh
```

`scripts/setup-poly-host.sh ruby|lua|js` builds mruby 4.0.0 (C++ exceptions, `scripts/mruby-rt-config.rb`), Lua 5.4.9 (`ldo.c` as
C++) and QuickJS-NG v0.17.0 with gcc and g++ under `build/poly-host/` (sources: GitHub's tarball of the pin, else the Ubuntu
archive's source tarball with a checked sha256; QuickJS file by file from raw.githubusercontent.com at the commit of the tag);
Go is `scripts/setup-poly-go.sh` (host Go >= 1.24, gcc, the module proxy), Python the system CPython (`python3-config --embed`). A
language whose engine cannot be built or downloaded is skipped with a `SKIP` line (exit status 3 of the setup script). With nfcxx
built, `tests/uop/run_poly.sh` uses the engines of `tests/poly/run.sh` for each back end (`NFCXX_BACKEND`, `POLY_LANGS`).

Run in the session that wrote this, with g++ 13.3, Python 3.12 (the `libpython3.12` of `python3-config --embed`), mruby 4.0.0, Lua 5.4.9, QuickJS-NG v0.17.0,
Go 1.24.7 with yaegi v0.16.1, and `cc` for the C backend: **1375 checks, 0 failed** (Ruby 302, Lua 283, Python 328, JavaScript 231,
Go 231), the exported model accepted by onnx.checker and onnxruntime 1.29; `tests/poly/ops.cpp` 114 checks in the five languages; `tests/poly/host.cpp` (the existing nfcpoly test, 1172 checks, all six engines) still passes with the backend and bridge
changes. **Not run**: the nfcxx back ends (EDG is not built here, so neither `tests/uop/run.sh` nor `tests/poly/run.sh` as CI
runs them; the code is standard C++17 in the style of the neighbours and compiles warning-free with `g++ -Wall -Wextra`), and
the sanitizers (the interpreters do not run clean under them, so `UOP_HOST` builds this test without).

## Limits and decisions

- **Lua has no `np.zeros(...)`**: Lua passes the receiver of a method call as the first argument, so the global `np` is used as
  `np:zeros(...)`. (A global function per name would put ~40 names in every script's global namespace.)
- **Comparison operators are absent in Lua** (a language rule: the result of `__lt`, `__le`, `__eq` is converted to a boolean) and
  **reflected operators in Ruby** (mruby's `Integer#-` raises `TypeError`, it does not call `coerce`): the named methods
  exist, and a test keeps the Ruby behaviour an error rather than a silent wrong value.
- **JavaScript and Go have no operators**; both use the named methods, as the design asked. Go's `any` parameters take tensors,
  numbers and lists; Go slices of numbers (`[]int`, `[][]float64`) work as lists.
- **ONNX bytes in JavaScript** come back as a `Uint8Array` (nfcpoly's rule for non-text bytes), which `Value::as<std::string>` does
  not read; the test takes it through `Array.from`. Python returns `bytes`, Ruby, Lua and Go strings.
- **Values cross by copy**: `tolist()` of a large tensor builds a nested list; there is no zero-copy buffer.
- **No sandbox**: `save_onnx(path, ...)` writes where the host process can (like the C++ call). As everywhere in nfcpoly.
- The `NumPy` object keeps the placeholders made through it (a name to Tensor map) so that a feed takes the placeholder's dtype.
  A feed for a name it does not know is `np: no placeholder named 'q'`; a placeholder that C++ made with `Session::placeholder` is
  fed from C++ (`Session::eval`), not from a script.
