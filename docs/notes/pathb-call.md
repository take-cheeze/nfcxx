# Direct and boxed calls across Path B producers

`lib/pathb/call.h` defines a C99/C++ call boundary independent of libuv and any language runtime. It does not replace a
language's internal value layout. A caller supplies a frame whose argument and result slots each identify a codec,
an owner/context pointer, and the address of a value in that owner's representation. A language adapter converts the
slots to its function's native signature. A known target can instead be called through its ordinary typed native entry.

The interface supports None, bool, signed i64, double, UTF-8 text, binary buffers, and retained opaque handles. Native
i64 entry points remain available as a fast boundary; generic boxed entries use owned `NfcValue` snapshots. Optional
adapters cover mrbbc, nfcast, tvm-ffi, libtorch and Qt Core. This does not replace a producer's own internal calling
convention or generate unboxed language bodies automatically.

## Frame contract

`NfcCallable` pairs an entry with its closure. `nfc_call_invoke` checks ABI version 2, slot addresses, and result capacity,
clears the previous diagnostic/result count, then invokes the entry. `NfcCallFrame` carries an argument array/count, a
result array/capacity/count, an opaque caller context, and a bounded diagnostic buffer. Both arrays and all values are
borrowed for the duration of the call. Generic conversion snapshots own their copied buffers and retained references.

Version 2 extends `NfcCallCodec` with `read_value` and `write_value`. Rebuild consumers, runtimes and adapters together;
do not mix version-1 binaries or codec tables. Callee-side argument helpers reject version-1 frames before reading the
new callback fields, even if an old caller validated its frame using its own old header.

The statuses are success, invalid frame, wrong arity, wrong type, unsupported operation, exception, and suspension.
Suspension is reserved: no current adapter implements continuations or permits a frame's stack pointers to escape.
Only `nresults` values are valid after success; it is zero after failure. A failing codec may have modified its result
slot, so result writes are not transactional. Codecs return a status and must not throw a foreign exception or longjmp
across the call boundary. An adapter catches errors belonging to its own runtime.

The caller keeps argument and result slots alive and registered with the owning GC throughout the call, including
reentrant calls and codec allocations. The owner pointer is passed to the codec; it can identify a runtime/realm but does
not itself pin a value. This keeps runtime-specific GC and ownership rules out of the common interface.

`NfcI64Target` describes a fixed arity, a generated vector thunk, and its closure. Its arity must match the thunk's
signature. `nfc_call_i64_entry` reads all arguments before invoking the target or writing the result, allowing aliased
argument/result slots. It supports up to 64 arguments and exactly one result, using a bounded C-stack temporary with no
heap allocation. The common frame itself supports other arities and multiple results through other adapters.

For an ordinary C function `int64_t add(int64_t, int64_t)`, a vector thunk calls `add(args[0], args[1])`. Call `add`
directly when the native signature is known, or use `{nfc_call_i64_entry, &target}` with the same implementation when
the caller supplies boxed slots. C++ can use the same interface without linking a language runtime.

## Owned values and callable lifetime

Zero-initialize each `NfcValue` (`NfcValue value = {0}` in C, `NfcValue value{}` in C++). Use `nfc_value_copy`,
`nfc_value_move`, and `nfc_value_clear`; a plain struct copy of a live owning value is not an ownership transfer.
`nfc_call_value_slot` exposes this representation to a frame. `NfcValueTarget`/`nfc_call_value_entry` marshal up to 64
arguments to a generic callback and publish one result, cleaning all temporary values on success or partial failure.
`call_value.hpp` supplies C++ RAII wrappers and reference-counted handle cells.

| Value | Ownership/conversion rule |
| --- | --- |
| None | A successful single None result has `nresults == 1`; it is not a failure or zero results. |
| bool / i64 / double | Kept distinct; there is no implicit bool-to-int or int-to-double coercion. Double preserves signed zero and supports NaN/Infinity. |
| UTF-8 text | `nfc_value_set_data(..., NFC_VALUE_TEXT, ...)` validates UTF-8, including surrogate/overlong/out-of-range rejection. Embedded NUL is valid. |
| bytes | Every byte is preserved, including NUL and invalid UTF-8. Both buffer kinds carry an explicit size and own a copy. |
| opaque handle | `NfcHandleOps` retains/releases an owner-specific reference. Its callbacks and type token must outlive all references; a foreign domain is never reinterpreted as a local object. |

Buffers remember an allocating-module release callback, so cleanup does not assume the same C allocator across DLLs.
Keep release callbacks' modules loaded until their values are cleared.
Read codecs produce owned values and write codecs copy/retain without consuming the source. All input snapshots are
taken before the target runs or an aliased result is written. A failed partial read is still cleaned. Callable providers
and slots remain responsible for their runtime's thread and GC rules; retaining a handle does not make a runtime
thread-safe. Qt object handles track a `QPointer` rather than owning/deleting a parent-owned QObject. nfcast handles pin
values while their State exists; an expired State is rejected safely. Tensor/IValue and tvm-ffi object handles retain
their native references strongly. Handles are process-local, not serializable remote object IDs.

For an exported callable whose closure is dynamically owned, pass a handle lease to `tvm::create_function(fn, &out,
&owner)`, `libtorch::BoxedKernel(fn, arity, &owner)`, or `qt::CallableObject(fn, parent, &owner)`. The wrapper retains
that owner and each in-flight invocation takes an additional lease. This permits provider/controller release, including
QObject deletion during a callback, without freeing the active closure. Omitting the lease preserves the explicit
borrowed-closure contract; it is appropriate for static or externally managed providers. The lease must actually own
the closure storage and any required runtime resources.

Calls remain synchronous. Owned snapshots can be copied into application-owned work items, but callers must not retain
a frame, a native slot pointer, or its borrowed owner/context after return. There is no completion/continuation or
queued-result protocol yet; suspension remains reserved.

## mrbbc exports

Request an explicit integer boundary for a top-level Ruby method:

```sh
scripts/setup-mrbbc.sh
scripts/setup-qbe.sh
mkdir -p build/call-library
OUT_DIR=build/call-library OUT_SYMBOL=library \
  bundle exec ruby bc2cpp/tools/bc2cpp/bc2cpp.rb --backend=mrbbc \
  --mrbbc-export-i64=sum --mrbbc-export-i64=answer tests/mrbbc/call/library.rb > build/call-library/library.ir
```

The lowerer also accepts `--export-i64=NAME` directly. Exports require an ASCII identifier and a top-level method with
only required positional parameters; every definition of that name must have the same arity. Optional/rest/keyword
signatures and class-only methods are refused atomically. No export is generated by default.

For `sum(a, b)`, lowering emits these C-compatible native symbols:

```c
int64_t mrbbc_i64_sum(int64_t a, int64_t b);
int64_t mrbbc_i64v_sum(void *closure, const int64_t *args);
```

The typed entry roots a temporary MV frame, boxes its arguments, looks up the initialized method definition, invokes
the existing Ruby body, and checks/unboxes its Integer result. This preserves dynamic definitions and Ruby semantics.
It is a typed native boundary, **not an unboxed-body optimization**: internal calls and the body still use the existing
MV ABI. The vector entry calls the same typed entry and fits `NfcI64Target`:

```c
NfcI64Target target = {2, mrbbc_i64v_sum, NULL};
NfcCallable callable = {mrbbc_call_entry, &target};
/* frame args/results may mix native i64 slots, mrbbc_call_slot(MV*), and other codecs. */
NfcCallStatus status = nfc_call_invoke(&callable, &frame);
```

Emit the IR with `scripts/pathb-qbe-emit.rb` and QBE as usual. Link the assembly with `tests/mrbbc/runtime/mrbrt.c`,
`mrbrt_call.c`, and your embedding driver. Include `mrbrt_call.h` in that driver and initialize the module with
`mrb_irep_0` before calling exports. Run initialization and calls under `mrbbc_run`; register every external MV slot
with `mrbbc_gc_enter` before creating values or passing them to codecs. Libuv is not required.

The mrbbc adapter protects conversion and execution with a nested `mrbbc_protect` boundary. An uncaught Ruby runtime
error becomes `NFC_CALL_EXCEPTION` with a diagnostic, rather than terminating the host. It frees tracked temporary
byte buffers before jumping, restores GC frames/protections, inspect recursion state and nonlocal-return state, and
allows a subsequent call. Ruby heap mutations made before failure remain. Ordinary execution without a protected
boundary retains its existing stderr/exit behavior; a direct typed call follows that behavior unless the host protects
it explicitly. This is an embedding error boundary, not Ruby `rescue` support. Process exits/traps are not converted.
The runtime remains one global, synchronous state; this interface does not make it thread-safe.

### Generic boxed Ruby methods

`MrbbcValueTarget{"method_name", arity, utf8_result}` with `mrbbc_value_call_entry` invokes an initialized top-level
method without requesting an i64 export. It roots arguments/results through the normal MV frame and method dispatch.
Ruby supports None/nil, bool, i64 and byte Strings here; `utf8_result = 1` requests a String result validated as text.
The current mrbbc runtime does not implement Float, so a double argument is explicitly unsupported. Text and binary
arguments both become Ruby byte Strings; readback is bytes unless the target requests UTF-8 text.

Opaque handles become `ForeignObject` GC objects with domain-checked payloads and a finalizer. A Ruby method can pass
them through calls and containers; collection releases its retained reference. This enables Tensor and QObject handles
to cross an allocating Ruby method without exposing native memory as MV fields. It does not provide Ruby syntax for
calling arbitrary native-object members. Outside references survive Ruby collection independently.

## Validation

`bundle exec ruby tests/bc2cpp/mrbbc_call.rb` compiles explicit exports through bc2cpp, Path B and QBE in all three MV
layouts with GC threshold 1. A native driver compares typed calls, boxed calls with mixed codecs, boxed Integer results,
aliasing, full-width integers, nested C-to-Ruby calls, exception recovery, and invalid frames/signatures. It also builds
and runs a standalone C++ caller. A second native driver covers generic values, UTF-8/binary data, aliasing, partial
conversion cleanup, handle finalization and version rejection. Set `RT_CFLAGS='-fsanitize=address,undefined -g -fno-omit-frame-pointer'` to instrument
the C runtime and adapter; generated QBE assembly is not sanitizer-instrumented.

## tvm-ffi, libtorch boxed calls, and Qt objects

These are optional C++ adapters. They include their vendor headers only when selected; the core C interface and mrbbc
runtime still need none of these SDKs or libuv. The real-library tests use compiled Ruby through Path B/QBE, not
substitutes for the vendor APIs. Scalar, string and opaque-object conversions use the shared owned-value protocol.

| Adapter | External caller to a compiled callable | Shared frame to the external runtime |
| --- | --- | --- |
| `lib/pathb/call_tvm.hpp` | `create_function` creates a real tvm-ffi Function with `TVMFFISafeCallType`; callers use `TVMFFIFunctionCall` | `Target{function, arity}` and `entry` pack owned `TVMFFIAny` arguments and call that Function |
| `lib/pathb/call_torch.hpp` | `BoxedKernel` registers a callable with libtorch's dispatcher as a stateful boxed kernel | `Target{OperatorHandle}` and `entry` invoke `callBoxed` on an `IValue` stack |
| `lib/pathb/call_qt.hpp`, `call_qt.cpp` | `CallableObject` exposes a `call(QVariantList)` Qt slot, reflected error properties, and result/error signals | `MethodTarget` invokes a reflected method; `PropertyTarget` reads/writes a declared property |
| `lib/pathb/call_nfcast.hpp` | `import_callable` installs a shared callable as a GC-managed nfcast native function | `Target` and `entry` call a pinned script/native function through `State::call` |

For tvm-ffi, wrap an existing callable with:

```cpp
TVMFFIObjectHandle function = nullptr;
nfc::pathb::tvm::create_function(callable, &function);
// TVMFFIFunctionCall(function, args, nargs, &result), with result initialized to None.
// Release the owned Function with TVMFFIObjectDecRef when finished.
```

The Function owns its callable descriptor and optional provider lease. Targets borrow their Function handles. Generic
codecs support None, bool, integer, float, text/bytes (small, owned, and borrowed views), and retained native objects.
Generic result writes construct a replacement before releasing any old owned object; the specialized i64 codec still
rejects replacing an owned object. The safe-call result must start as None, as required by tvm-ffi. Vendor errors are moved from tvm-ffi TLS, copied to the frame diagnostic,
and released; compiled runtime failures become tvm-ffi errors at its safe-call boundary.
See the [tvm-ffi ABI contract](https://tvm.apache.org/ffi/concepts/abi_overview.html).

For libtorch, register the callable against an explicit fixed integer schema:

```cpp
auto library = MAKE_TORCH_LIBRARY(my_callables);
library.def("sum(int a, int b) -> int", torch::CppFunction::makeFromBoxedFunctor(
    std::make_unique<nfc::pathb::libtorch::BoxedKernel>(callable, 2)));
auto op = c10::Dispatcher::singleton().findSchemaOrThrow("my_callables::sum", "");
// op.callBoxed(&stack), or use nfc::pathb::libtorch::Target{op} through the shared frame.
```

The kernel consumes the argument suffix and leaves values below the call frame intact. Failed calls preserve the input
stack. Keep the Library registration and callable closure/lease alive during calls. This bridge uses libtorch's versioned C++
API, not a stable C ABI: compile against matching headers, libraries, and `_GLIBCXX_USE_CXX11_ABI`. Schema validation
rejects variadic/multiple-result signatures and checks actual argument/result types against the schema. Scalar kinds,
strings, optional None, and native IValue objects such as Tensor are supported. Non-scalar IValues travel as retained
opaque handles; they can round-trip through compiled Ruby and be used by native boxed operators such as
`aten::add.Tensor`. This is not automatic DLPack conversion between tvm-ffi and libtorch. Native libtorch strings use
one representation for text/bytes: valid UTF-8 is read as text, other contents as bytes; byte contents remain unchanged.
Native libtorch exceptions become frame status; compiled exceptions become C++ exceptions for dispatcher callers.
The reference implementation is [PyTorch's boxed dispatcher](https://github.com/pytorch/pytorch/blob/main/aten/src/ATen/core/dispatch/Dispatcher.h).

### Qt Core details

`CallableObject` is a real `QObject` with `Q_OBJECT`; run `moc` on `call_qt.hpp` and link that output with `call_qt.cpp`
and Qt6::Core (or enable CMake AUTOMOC and list both files in the target). No GUI or widgets are needed.

```cpp
nfc::pathb::qt::CallableObject object(callable);
QVariant result;
QVariantList args{20, 22};
QMetaObject::invokeMethod(&object, "call", Qt::DirectConnection,
                         Q_RETURN_ARG(QVariant, result), Q_ARG(QVariantList, args));
// Connect a QVariantList signal to CallableObject::call; observe valueReady(QVariant)/callFailed(QString).
```

`lastStatus` and `lastError` are reflected read-only properties; failures return an invalid QVariant and emit
`callFailed`, without throwing through Qt's slot boundary. A successful None/void result is also an invalid QVariant,
distinguished by `lastStatus == NFC_CALL_OK`. `valueReady` reports every result; the original `resultReady(qlonglong)`
signal is retained for integer results. Methods/properties support `int`, `qlonglong`, bool, double, QString, QByteArray,
and QObject pointers. Methods can also use QVariant or return void. Int narrowing is range-checked; bytes passed to a
QString parameter must be valid UTF-8. QStrings with unpaired surrogates are refused instead of silently replaced.
`MethodTarget` accepts at most ten arguments; `PropertyTarget` handles declared properties. A property write returns
the converted assigned value and lets Qt's normal setter/NOTIFY signals run. Dynamic properties and arbitrary method signatures
are not supported yet. See [Qt's meta-object system](https://doc.qt.io/qt-6/metaobjects.html).

Targets use `QPointer` to reject deleted objects. The wrapper also checks its lifetime after foreign calls and property
notifications, since a connected handler may delete it. Calls are synchronous and require the object's owning thread;
the wrapper also stays bound to its creation thread. Create it on the language runtime's owner thread and keep that
runtime active for the duration of the Qt interaction. This does not make a language runtime thread-safe. No queued
result protocol or cross-thread blocking dispatch is introduced. As with ordinary Qt callbacks, connected slots must
not throw C++ exceptions through Qt signal activation. Define `QT_NO_KEYWORDS` when combining Qt and libtorch headers;
the adapter uses Qt's explicit `Q_SIGNALS`/`Q_SLOTS`/`Q_EMIT` macros.

### nfcast connection

`lib/pathb/call_nfcast.hpp` connects the public nfcast embedding API in both directions. `ast::RootedSlot` pins native
slots with `State::pin`/`unpin`; `ast::Target(state, function, arity, utf8_result)` exposes `State::call` as an entry.
`ast::import_callable(state, callable, name, owner)` creates a GC-managed native binding that can be installed in the
script's globals. Its optional provider lease is owned by a HostObject referenced through the native function's upvalue.
The adapter handles nil/bool/integer/float/byte strings, errors, and opaque references; text results are an explicit
validated projection. Non-scalar nfcast values use GC pins while the State lives; stale handles/targets fail after that
State closes. A foreign-domain handle is stored in an opaque HostObject rather than reinterpreted.

```cpp
auto state = std::make_shared<nfcast::State>();
state->open_libs();
auto imported = nfc::pathb::ast::import_callable(state, callable, "foreign", &owner);
state->globals->set_str(*state, state->str("foreign"), imported->get());
// Scripts can now call foreign(...). RootedSlot keeps its native value pinned across collections.
```

This is wiring at the normal boxed call boundary: nfcast scripts can call compiled mrbbc methods and shared clients
can call nfcast functions, with both GCs active. It does not replace nfcast's own Value, AST call nodes, C tier or JIT
calling convention, nor add a specialized direct-call fast path to those tiers. The existing native-function dispatch
is reused. Multiple nfcast return values are refused rather than silently truncated.

### Real-library test

```sh
# Build tvm-ffi's C++ runtime with CMake; no Python package or interpreter is required.
# LIBTORCH can name a standalone C++ distribution or a directory containing torch's include/, lib/, share/.
CXX=clang++ TVM_FFI_ROOT=/path/to/tvm-ffi TVM_FFI_LIBDIR=/path/to/tvm-ffi/build/lib \
  LIBTORCH=/path/to/libtorch QT6=1 bundle exec ruby tests/bc2cpp/mrbbc_external_call.rb
```

Select any subset with `TVM_FFI_ROOT`, `LIBTORCH`, `QT6=1`, or `NFCAST=1`; the last builds the repo's nfcast engine once
and tests shared-frame → nfcast script → compiled Ruby, errors/recovery, floating functions, pins and handle lifetime.
`QT6_PREFIX` supports a separate Qt installation and `MOC`
overrides the tool. The runner uses pkg-config for Qt, discovers libtorch's required C++ string ABI from its CMake
configuration (`TORCH_CXX11_ABI` overrides it), and accepts `CXXFLAGS` for compiler flags. GCC 15 with libtorch 2.14.1
can emit an optimized `IValue`/intrusive_ptr `-Wstringop-overflow` diagnostic under `-Werror`; Clang is tested at `-O1`,
and GCC is tested at `-O0` (`CXXFLAGS=-O0`). No warning is globally suppressed in the adapter.

With all three selected, the runner also tests **Qt meta-call → libtorch boxed dispatcher → tvm-ffi Function → compiled
Ruby**, returning through every representation. It checks integers, Unicode/NUL text, binary data, bool, None, an error
originating in Ruby, and a successful call afterward. A native generic target covers the double path because mrbbc's
runtime currently refuses Float. Native Tensor operations, handle/owner release, and QObject deletion during an
in-flight owned call are also tested. Every scenario runs in all three MV layouts with GC threshold 1. `MRBBC_VALUES=8` selects
one layout; `RT_CFLAGS='-fsanitize=address,undefined -g -fno-omit-frame-pointer' ASAN_OPTIONS=detect_leaks=0` instruments
our runtime/adapters (vendor binaries and QBE assembly remain uninstrumented). Tested locally with tvm-ffi commit
`05e3a7c5568b5e21c92f50aa7b916fe25e674b61`, CPU libtorch 2.5.1 and 2.14.1, and Qt 6.10.2.

`.github/workflows/pathb-external-call.yml` provides a manual-only reproduction with pinned tvm-ffi, the standalone CPU
libtorch 2.5.1 C++ distribution, and Ubuntu's Qt Core development files. These large optional SDKs are not downloaded
by ordinary PR CI.
