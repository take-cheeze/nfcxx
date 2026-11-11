# The Path B front end in the browser (EDG's cpfe built with Emscripten)

Status: **builds and matches the native front end.** `PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh` builds the Path B
harness (EDG with `be/nfcxx_be.c` and `be/nfcxx_ir.c`, `docs/notes/pathb-stage1.md`) as a WebAssembly module. On the
151 C and C++ files of `tests/pathb-wasm-frontend/run.sh` its IR is byte for byte the native front end's on 149, and
the other two are known differences where the browser build is the correct one (below). With mruby built with
Emscripten too (`scripts/setup-mruby-wasm.sh`, for the emitter), the wasm explorer's static site compiles C, C++, LLVM
IR and the IR in the page, with the server's result byte for byte (`docs/notes/wasm-explorer.md`, "Static build").

## Build and run

```
scripts/setup-emsdk.sh                          # Emscripten 6.0.13 into build/emsdk
source build/emsdk/emsdk_env.sh
PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh       # build/pathb-wasm/cmake/bin/cpfe.js and cpfe.wasm, about 4 minutes
scripts/pathb-dump-wasm.cjs --ir prog.cpp       # pathb-dump's options and output, the wasm front end under node
tests/pathb-wasm-frontend/run.sh                # the native and the wasm front end on the same files
```

`cpfe.wasm` is 17.9 MB (4.4 MB gzip), `cpfe.js` 74 KB. The module is `createCpfe` (`-sMODULARIZE`): one instance per
compilation, whose `callMain(argv)` runs the front end, with Emscripten's in-memory file system (`FS`) and environment
(`ENV`) exported. The front end needs in that file system: EDG's base directory (`build/pathb-wasm/edg-base`: the
predefined macros and EDG's own headers, about 300 KB), the source, and for a hosted compilation the host's system
include directories. `pathb-dump-wasm.cjs` copies them in before the call, as a page would. Under node a small file
takes about 80 ms to instantiate and 80 ms to compile; a hosted C++ file that includes `<vector>`, `<string>` and
`<map>` about 2 s, most of it copying the headers in.

## What the build changes, and why

EDG infers its configuration from the host compiler: it assumes it runs on the machine it compiles for. The browser
build runs on wasm32 and compiles for x86-64 Linux, like the native one, so the target is stated explicitly and the
host-dependent parts are replaced. All of it is in `setup-pathb.sh` (the `PATHB_EMSCRIPTEN` branches); the submodule is
not modified, the build tree's copies are.

| What | Native (x86-64 gcc) | wasm32 | Done in the browser build |
| --- | --- | --- | --- |
| The Linux configuration (`defines.h` selects `defines_linux.h` by `__linux__`) | `__linux__` | not defined | `-D__linux__` for cpfe's sources |
| The x86-64 target, x86 `asm` constraints and attributes (`TARG_SUPPORTS_X86_64`, `GNU_X86_*`, from `__x86_64`) | from the host | not x86 | set in the macro configuration |
| The host alignments EDG checks at start-up (`HOST_ALIGNMENT_REQUIRED`, `HOST_POINTER_ALIGNMENT`) | 8, 8 | 8, 4 | set |
| The host integers holding target sizes (`a_host_large_unsigned` is `size_t`) | 64-bit | 32-bit: `SIZE_MAX` became 2^32 - 1 | `targ_def.h` copy: `long long` |
| `TARG_SIZE_T_MAX` (host `ULONG_MAX` by default) | 2^64 - 1 | 2^32 - 1 | set to 2^64 - 1 |
| Floating point | `__float128` host values, libquadmath | a target `long double` (x87 80-bit) kept in the host's `long double` is wrong: wasm32's is binary128 | SoftFloat (`USE_SOFTFLOAT`, as EDG's Windows configuration): Berkeley SoftFloat 3e, pinned, x86 NaN rules, built with emcc |
| `__isnan` (glibc, `float_pt.c` under `__linux__`) | glibc | musl has none | `-D__isnan(x)=__builtin_isnan(x)` |
| The error tables (`mk_errinfo`, run at build time) | a program | run under node | `-sNODERAWFS` so that it writes the files |

And in the back end (`be/`), which assumed an LP64 host:

- **`long` is 64 bits.** `be/nfcxx_ir.c` held 64-bit target values (constants, the halves of a long double or a 128-bit
  integer, sizes, offsets, hashes) in `long` and printed them with `%lu`/`%ld`: on wasm32 a long double constant lost
  its high words. Every `long` is now `long long` (`%llu`, `ULL`, `atoll`). On LP64 the two are the same width, and the
  native IR of all 151 files is unchanged.
- **The order of evaluation of a call's arguments.** Four places passed two IR-emitting calls as arguments of one
  call (`islessgreater` and `isunordered`, the long double `islessgreater`, a compound assignment's operand
  conversions, a zeroed bit-field). gcc evaluated the last argument first, clang (Emscripten) the first, so the
  statements came out in another order. They are now sequenced, in gcc's order, so the native IR is unchanged.

## Known differences

`tests/pathb-wasm-frontend/known.txt`: a `double` to `_Float16` conversion that overflows or is inexact. SoftFloat folds
it to the correctly rounded value (`+Infinity`, `65504.0`); the native build keeps it as a run-time conversion, or, in
a static initializer, folds it to `0.0`. `tests/c/float16_golden.inc`'s expected bits (gcc's) for `f16_folds` are the
browser build's infinities, so there the native front end is wrong. That is a bug of the native configuration's
floating point (the host path), not of this build.

## Why wasm32 and not wasm64

A wasm64 (memory64) build would have made the host LP64 like the native one, without the back end's `long` change or
the alignment and integer settings. Chrome and Firefox ship memory64, Safari did not (2025), so the front end stays
wasm32, which every browser runs. SoftFloat is needed either way: wasm64's `long double` is binary128 too.

## mruby for the browser

`scripts/setup-mruby-wasm.sh` builds the interpreter of `scripts/mrb` with Emscripten (mruby's own `emscripten`
toolchain, wasm exceptions for its `setjmp`), `createMruby` like `createCpfe`: `build/mruby-wasm/out/wasm/bin/mruby.js`
and `mruby.wasm` (0.9 MB, 0.3 MB gzip). Its `Integer` is 64-bit (`MRB_INT64`, with `MRB_NO_BOXING`, which mruby needs
for it on a 32-bit target): mruby's default on wasm32 is 32-bit, and with it the emitter's output changed (a LEB128
encoding of a 64-bit value). `tools/wasm-explorer/inbrowser.js` runs both tools; its stdout is captured as bytes
(`FS.init`), since the emitter writes a binary module there.

## Next steps

1. **Hosted headers**: the page has EDG's own headers only, so a program that includes `<stdio.h>` or `<vector>`
   compiles on the server only. The host's headers are about 17 MB (libstdc++ 14 MB, GCC's own 3 MB, glibc's); a
   bundle of the headers a program actually includes, loaded on demand, would bring the common ones.
2. **Demangling** in the page (a trap's frames show `_Z4deepi`, where the server shows `deep(int)` through c++filt).
3. **Rust**: mrustc's monomorphised MIR to Path B IR (`docs/notes/mrustc-monomir.md`), the same IR, so C and Rust can be
   one module. Go has no front end of nfcxx's own (TinyGo stays on the server).
