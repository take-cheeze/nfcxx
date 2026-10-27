# nfcxx documentation

`docs/DESIGN.md` is the design and the original plan. `docs/notes/` holds one note per piece of work. Notes are
written as work happened, so a later round can supersede an earlier statement inside a note; this page is the
current-state summary, and every claim in it names the test script that covers it. Claims that no script
covers say so.

## Index of `docs/notes/`

| Note | One line |
| --- | --- |
| [build-self-hosting.md](notes/build-self-hosting.md) | What the build fetches, which host tools it needs for which step, and how to build offline from mirrored submodules. |
| [asan.md](notes/asan.md) | `nfcxx -fsanitize=address`: AddressSanitizer on the qbe (default) and gcc backends; backend selection, limits. `tests/asan/run.sh`. |
| [asan-plan.md](notes/asan-plan.md) | Plan for AddressSanitizer on Path B and wasm (the qbe milestones are done): emitter checks, libasan reuse, milestones. |
| [builtins.md](notes/builtins.md) | Table of compiler builtins: what EDG accepts per dialect and what runs on the gcc and qbe backends. |
| [cxx-driver.md](notes/cxx-driver.md) | `nfcxx` as `CXX` for CMake and mruby: the driver options accepted (`find_package(Torch)`'s `--no-as-needed` spans, CMake 4's linker dependency file), and the rpg-maker-clone desktop build's remaining blockers. |
| [sqlite.md](notes/sqlite.md) | SQLite 3.54.1 built with nfcc (`scripts/setup-sqlite.sh`) and `lib/sqlcache`, a TTL key-value cache on it. `tests/sqlite/run.sh`. |
| [astro.md](notes/astro.md) | ASTro (ko1/astro: ASTroGen, partial evaluation into C, a Code Store that compiles with `$(CC)`) built with nfcc: calc, luastro, baruby_precise and koruby_precise (with Prism, and astrogre's regex engine) on both backends, two patches for Ruby 3.3 and cproc, and the cproc and nfcc changes it needed (GNU statement expressions, weak definitions in C, `--param`). `tests/realworld/run_astro.sh`. |
| [libclang-edg.md](notes/libclang-edg.md) | libclang's C API on the EDG front end: `build/libclang-edg/libclang-edg.so`, with a back end that lists the declarations (`be/nfcxx_decl.c`), the `clang.cindex` binding walking them, generated stubs for the rest, and the known differences from libclang 18. `tests/libclang-edg/run.sh`. |
| [call-abi.md](notes/call-abi.md) | Registers or a hidden pointer for a class in a call (IA-64 ABI), decided as g++ does: C++20 conditionally trivial copy and move constructors (P0848, libstdc++'s `std::optional<T>`) and a deleted copy constructor beside a trivial move constructor; the EDG fixes. `tests/call-abi/run.sh`. |
| [cuda-driver.md](notes/cuda-driver.md) | A link that names libcuda (`-lcuda`, CMake's `CUDA::cuda_driver`, which libtorch's package adds) goes through libcudart instead, by default (`--cuda-driver=auto|cudart|libcuda`; `scripts/cuda-driver-shim`, `lib/cuda/driver`): the program links and starts without libcuda.so.1, cudart loads the driver at run time; the per-name ABI versions from cuda.h and cudaTypedefs.h; cuBLAS and cuDNN on a GPU. `tests/cuda/driver/run.sh`, `tests/cuda/gpu/run.sh` (GPU, by hand). |
| [bundle.md](notes/bundle.md) | `--bundle-libs` on nfcxx and nfcc (`tools/bundle`, `build/nfcbundle`): the shared libraries an executable or shared object needs, libstdc++ included, copied into it (merged TLS, `.eh_frame_hdr`, init order, symbol binding), in the spirit of pfnet/sold; stubs for plugins; libtorch with CUDA (2.4 GB bundle, by hand: `tests/bundle/torch.sh`; on a GPU, and what `find_package(Torch)` with nfcxx still lacks); cuDNN's dlopen of libcublasLt and its full-version names; the limits. `tests/bundle/run.sh`. |
| [ffi.md](notes/ffi.md) | `nfcffi` (`lib/ffi`): compiling C source at run time with `nfcxx -shared` and calling its functions, and the C library's, through typed C++ function types (no libffi), the signatures of a header's functions read from the front end (`Ffi::declarations`), and calls by name with runtime-typed values (`Ffi::load`, `Library::call`); `tests/ffi/run.sh`. |
| [eval.md](notes/eval.md) | `nfceval` (`lib/eval`): evaluating C++ snippets at run time with bound host objects, and `nfcxx -shared`. |
| [eh-shim.md](notes/eh-shim.md) | Exceptions thrown by libstdc++.so (`std::__throw_*`), by any gcc-compiled code (`__cxa_throw`, `__cxa_rethrow`: libtorch's `c10::Error`) and `std::exception_ptr` on EDG's exception runtime: the shim library, the runtime hooks, libstdc++'s vtables for libC.a's `type_info` objects, link order, limits. |
| [freestanding.md](notes/freestanding.md) | The `lib/` headers, `nfcxx --freestanding`, `--target=` (EDG layout for linux_aarch64, linux_armv7, linux_riscv64 and win64; generated C only; a win64 probe runs under wine), and the cproc limits met while writing them. `tests/target/run.sh`; the probes run nightly under qemu-user and wine in `emulators.yml`. |
| [gpu.md](notes/gpu.md) | GPU first step: a hand-written IR kernel, lowered to PTX by `tools/pathb-ptx-emit`, run with ptxas and the CUDA runtime on an RTX 2060 (`tests/gpu/run.sh`). |
| [sycl-vulkan.md](notes/sycl-vulkan.md) | SYCL subset on Vulkan: the SPIR-V emitter (`scripts/pathb-spirv-emit.rb`, physical-address pointers, 64-bit and double), the device-heap runtime (`rt_vulkan.hpp`), checks through a dead flag, lavapipe tests and the next steps (Intel Arc, Level Zero). `tests/sycl/run.sh`. |
| [sycl-kernel-builtins.md](notes/sycl-kernel-builtins.md) | The `__builtin_sycl_*` kernel-info builtins the oneAPI `<sycl/sycl.hpp>` headers call (EDG, `nfcxx/sycl-kernel-builtins`): what each yields, the open limits (lambda captures, run-time parameter index, the header's kernel-size check). `tests/cases/sycl_*`. |
| [sycl-webgpu.md](notes/sycl-webgpu.md) | SYCL 2020 subset on WebGPU: `lib/sycl` header library, the IR-to-WGSL emitter `scripts/pathb-wgsl-emit.rb`, the pointer model, USM by identity-mapped addresses, the Node/Chromium runtime, API coverage and a sweep of oneAPI-samples. `tests/sycl/run.sh`. |
| [hexagon.md](notes/hexagon.md) | Generated C through clang for Hexagon, run on qemu-hexagon; what blocks a real Hexagon target. |
| [llamacpp.md](notes/llamacpp.md) | llama.cpp's host-side ggml through the gcc backend: what compiles, the driver fixes, and the blockers (EDG AVX10.2 builtins, a cross-TU template instance). `tests/llamacpp/run.sh`. |
| [modules.md](notes/modules.md) | C++20 named modules (`export module`, `import`): the one-command and separate-compile routes, the refusals, and the gaps (standard headers in the global module fragment, unions in the reader). `tests/modules/run.sh`. |
| [mruby-scripting.md](notes/mruby-scripting.md) | The build's helper scripts run on a self-built mruby instead of Python; how each port is verified byte for byte. |
| [cpp2.md](notes/cpp2.md) | Experimental: `.cpp2` (Cpp2) inputs translated by cppfront (`scripts/setup-cppfront.sh`) before the C++ pipeline; `tests/cpp2/run.sh`. EDG rejects cpp2util's `CPP2_UFCS` lambda, which blocks most of cppfront's regression suite. |
| [mrustc-frontend.md](notes/mrustc-frontend.md) | Rust programs built by mrustc, with the program's C compiled through cproc and QBE (`scripts/mrustc-nfcc.sh`, `tests/mrustc`): the rewrites mrustc's C needs, and what is still gcc-built (the standard library). |
| [mrustc-borrowck.md](notes/mrustc-borrowck.md) | Rust programs borrow-checked through mrustc's MIR and `scripts/pathb-borrowck.rb` (`scripts/mrustc-borrowck.sh`, `tests/mrustc-borrow`): the facts the monomir translator emits, mrustc's own verdicts, and the cases compared with rustc. |
| [ast.md](notes/ast.md) | `nfcast` (`lib/ast`): a self-specializing AST interpreter for a Lua 5.4 subset and the three steps of a Truffle-style plan (the AST level of the third): nodes that rewrite themselves, a tier that compiles hot numeric kernels through the nfcxx driver, small script functions inlined at hot call sites by cloning their bodies, its own collector, differential tests against a real Lua. `tests/ast/run.sh`. |
| [poly.md](notes/poly.md) | `nfcpoly` (`lib/poly`): evaluating Ruby (mruby), Lua, Python, JavaScript (QuickJS-NG), Go (yaegi) and `ast` (the nfcast engine) from C++ with bound host objects, GraalVM-polyglot style; mruby and Lua are built with C++ exceptions on EDG's runtime, QuickJS is plain C patched for cproc, Go is a statically typed binding model over a cgo shared library; the exception model and its test. |
| [uop.md](notes/uop.md) | `nfcuop` (`lib/uop`): a tinygrad-style UOp IR (hash-consed nodes, shapes, rewriting, a reference interpreter), an ONNX-style graph (`hir`) with ONNX export, and a numpy-like `np::Tensor` API over it; measured numpy compatibility, the static-then-dynamic shape plan. C rendering (`render_c`), autodiff (`uop-autodiff.md`) and the script-language bindings (`uop-poly.md`) are in; dynamic shapes and ONNX import still to come. `tests/uop/run.sh`. |
| [uop-poly.md](notes/uop-poly.md) | `nfcuop_poly` (`lib/uop`): the numpy-like `np::Tensor` API in Ruby, Lua, Python, JavaScript and Go through `nfcpoly`: operators where the language has them, named methods everywhere, nested lists in and out, ONNX bytes identical to the C++ model's; what was run (host g++) and what was not. `tests/uop/run_poly.sh`. |
| [uop-autodiff.md](notes/uop-autodiff.md) | Reverse-mode autodiff for `nfcuop` by **onnxsim** (`lib/uop/nfcuop_onnxgrad.*`, ONNX reader `nfcuop_onnx_import.cpp`): `hir::gradients_via_onnxsim` / `np::grad` export the loss' sub-graph, onnxsim (C++ library `libnfconnxsim.so` built by `scripts/setup-onnxsim.sh`, Python fallback `scripts/onnx_grad.py`) appends the gradient as ONNX nodes, and `merge_onnx` brings it back; operator coverage table, what was lost against the native rules, upstream patches (`notes/onnxsim-upstream/`), security note. `tests/uop/test_grad.cpp`, `test_onnx.cpp`. |
| [pathb-longdouble.md](notes/pathb-longdouble.md) | Path B `long double`: 16-byte objects, helper calls compiled by gcc, x87 thunks for the C calling convention; tests and named limits. |
| [pathb-stage1.md](notes/pathb-stage1.md) | Path B harness: a `cpfe` with our own back end that dumps EDG's lowered IL (historical; harness still used). |
| [pathb-stage2.md](notes/pathb-stage2.md) | The mid-level IR: structured control flow, typed three-address form, explicit checks; spec and coverage. |
| [pathb-borrowck.md](notes/pathb-borrowck.md) | Opt-in local lifetime analysis on annotated Path B IR: initialization, dangling accesses, local-address returns, refusal boundaries, and the next steps toward shared Rust/C++ borrow checking. |
| [pathb-stage3.md](notes/pathb-stage3.md) | The IR-to-QBE emitter, translation validation, and the rounds of closed gaps (volatile, TLS, exceptions, dynamic init, bit-fields, VLAs). |
| [pathb-wasm.md](notes/pathb-wasm.md) | The IR-to-WebAssembly emitter: the LP64 layout kept with i64 pointers, the ILP32 layout of wasm32 under `--emscripten` (i32 pointers), the 64-bit memory under `--memory64`, the shadow stack, traps, what is refused, and the node tests (`tests/wasm/run.sh`, with the Emscripten glue of emcc when it is installed). |
| [wasm-explorer.md](notes/wasm-explorer.md) | The wasm explorer page (`tools/wasm-explorer/`): compile C++ to wasm on a local server, run the module in the page; Compiler Explorer feature coverage; memory64 (wasm64) as a change to the emitter. |
| [realworld.md](notes/realworld.md) | tinyxml2, doctest, Lua, mruby built with nfcxx/nfcc, what each needed, `nfcc` options. |
| [pathb-llvm.md](notes/pathb-llvm.md) | Path B from LLVM IR (`scripts/llvm-to-pathb.rb`): `clang -S -emit-llvm` text to nfcxx IR, with `nsw` checked and the other policy choices; 9 programs run against `// EXPECT:` and clang -O0 (`tests/llvm-pathb/run.sh`); what is refused. |
| [pathb-cil.md](notes/pathb-cil.md) | Path B IR to CIL: C++ `try`/`catch` as CLR exceptions (spike), 19 of 62 IR test files translate, `tests/pathb-cil/run.sh`. |
| [cil.md](notes/cil.md) | `NFCXX_BACKEND=cil`: C programs compiled to .NET 8 assemblies (QBE IL -> CIL -> ilasm), the shim for variadic calls, what is not supported, `tests/cil/run.sh`. |
| [coreclr-gc.md](notes/coreclr-gc.md) | CoreCLR's workstation GC (34 translation units) compiled by nfcxx on both backends; the QBE rewrites it needed; what a link and run still needs. |
| [ubsan.md](notes/ubsan.md) | `nfcxx -fsanitize=undefined` (Path B): checked operations that report `file:line: runtime error: ...`, and `[[likely]]`/`[[unlikely]]` as block layout. `tests/pathb-qbe/run.sh` (traps/ubsan_*, cases/ubsan_clean, cases/likely_unlikely). |
| [safe-pointers.md](notes/safe-pointers.md) | `nfcxx -fsafe-pointers` (Path B, prototype): Fil-C-style memory safety checks. Pointer arithmetic stays in its object, accesses must hit a live object (heap, globals, escaping locals), use after free (a conservative collector keeps referenced freed blocks dead) and after return are found, calls through pointers are checked against the callee's signature; runtime `lib/safeptr`, limits and plan. `tests/safeptr/run.sh`. |
| [tracing.md](notes/tracing.md) | `--trace` Chrome/Perfetto JSON of the driver steps. |
| [cpp-feature-coverage-plan.md](notes/cpp-feature-coverage-plan.md) | Plan and remaining milestones for a per-paper C++ language feature matrix, using the pinned cpprefjp checklist. |
| [cpp-feature-matrix.md](notes/cpp-feature-matrix.md) | C++11/C++14 pilot: 51 focused feature probes on qbe, gcc and Path B, upstream compiler versions and reproduction steps (`tests/cpp-features/run.sh`). |
| [cpp-test-ci-plan.md](notes/cpp-test-ci-plan.md) | Local upstream snapshots, small PR checks, scheduled nightly Linux suites and weekly extended surveys. `tests/upstream/README.md`. |
| [library-suite-results.md](notes/library-suite-results.md) | Native libc++/libstdc++ baselines, Microsoft STL source portability survey, and reviewed library probes on nfcxx routes. |
| [upstream-suite-results.md](notes/upstream-suite-results.md) | Broad native GCC/Clang/EDG results and GCC positive-source survey through nfcxx. |
| [reference-suite-survey.md](notes/reference-suite-survey.md) | Full cppreference/cpprefjp compile surveys: 3,158/6,743 examples, plus language-only results on all nfcxx routes; candidates versus reviewed runtime assertions. |

## Status matrix

"Test" is the script that exercises the claim. "CI" is the workflow that runs it (`ci.yml`, `pathb.yml`,
`realworld.yml`, `hexagon.yml`); "none" means no workflow runs it. A test marked "needs X" skips or fails without X.

| Area | Supported (test) | CI |
| --- | --- | --- |
| C++20 modules (`export module`, `import`; `docs/notes/modules.md`): interface units with classes, templates, inline functions and enums, chains of imports, one-command and `-c` routes with `--module-dir` | `tests/modules/run.sh` (both backends) | ci.yml |
| Path A, gcc backend (`nfcxx --backend=gcc`: EDG's C through `gcc -O2 -fwrapv -fno-strict-aliasing`) | The 15 programs of `tests/cases` (`NFCXX_BACKEND=gcc tests/run.sh`); freestanding library (`tests/lib/run.sh`); builtin probes (`tests/builtins/run.sh`); C inputs (`tests/c/run.sh`); tinyxml2 (`tests/realworld/run.sh`); doctest on the hosted headers (`tests/realworld/run_doctest.sh`, gcc only) | ci.yml, realworld.yml |
| Path A, qbe backend (the default: EDG's C -> `qbe-prep` -> cproc -> QBE -> asm; `scripts/qbe-cc`) | Same `tests/cases`, `tests/lib`, `tests/builtins`, `tests/c`, tinyxml2 as above with `NFCXX_BACKEND=qbe` or the default; C++ exceptions (`tests/cases/exceptions.cpp`); signed overflow wraps (`tests/cases/signed_overflow_wraps.cpp`); Lua and mruby as C (`run_lua.sh`, `run_mruby.sh`); CoreCLR's workstation GC compiles, 34 translation units (`run_coreclr_gc.sh`, `docs/notes/coreclr-gc.md`) | ci.yml, realworld.yml |
| Path B (EDG lowered IL -> own IR -> QBE, `scripts/setup-pathb.sh`, `be/`, `scripts/pathb-qbe-emit.rb`) | IL goldens (`tests/pathb/run.sh`); IR goldens and node coverage (`tests/pathb-ir/run.sh`); IR -> QBE -> run, equal to `// EXPECT:` and to the gcc backend (`tests/pathb-qbe/run.sh`): arithmetic and control flow, `continue`, bool loads, `setjmp`, bit-fields (`cases/bitfield*.cpp`), VLAs including scope exit (`cases/vla*.cpp`), GNU statement expressions (`cases/stmtexpr*.cpp`), volatile (`cases/volatile.cpp`), thread-local objects (`cases/tls*.cpp`, `multi/tls_*`), dynamic initialization (`cases/dyn_*.cpp`, `multi/dyn_init`), C++ exceptions (`cases/eh_*.cpp`), `long double` (`cases/longdouble_*.cpp`, `multi/abi_ld`, `traps/longdouble_*`; `docs/notes/pathb-longdouble.md`), COMDAT/weak linkage (`multi/comdat`, `multi/weak_link`), checked operations that must abort with SIGABRT (`traps/`) | pathb.yml |
| Path B, hosted (`NFCXX_PATH=b ./nfcxx`, `scripts/pathb-cc`, `scripts/host-sys.sh`; `docs/notes/pathb-hosted.md`) | Programs using the host C and C++ headers and libstdc++: hosted probes `tests/pathb-qbe/cases/{hosted_*,abi_struct,vararg_def,base_null}.cpp` and `multi/abi_c`, `tests/cases` through the driver (`NFCXX_PATH=b tests/run.sh`), tinyxml2 (exit 12); all in `tests/pathb-qbe/hosted.sh`. doctest builds and exits 2 as expected (no CI script; `pathb-hosted.md`, "long double"). Several translation units sharing libstdc++ templates: `tests/multi-tu/run.sh` (`docs/notes/multi-tu.md`, both backends) | pathb.yml (hosted.sh), ci.yml (multi-tu) |
| EH shim (`lib/ehshim`, `scripts/ehshim`; `docs/notes/eh-shim.md`) | Exceptions thrown inside libstdc++ (`vector::at`, `std::stoi`, empty `std::function`, `string::_M_create`, `thread::join`, `promise`/`future`, `regex`) are caught by EDG-compiled handlers; `std::current_exception`, `exception_ptr`, `rethrow_exception`, `make_exception_ptr`, `throw_with_nested`; `new` failure on the gcc backend; plain `throw`s of a g++-built library caught by the program, the library's own handlers kept (`tests/ehshim/foreign`, also `NFCXX_EH_UNWIND=1`); `c10::Error` from libtorch (`tests/bundle/torch.sh`, by hand). Path A both backends, Path B: `tests/cases/eh_libstdcxx_throw.cpp`, `tests/cases/eh_exception_ptr.cpp` (all `tests/run.sh` modes and `tests/pathb-qbe/run.sh`), `tests/pathb-qbe/cases/hosted_eh_system.cpp`, and `tests/ehshim/run.sh` (output compared with host g++). `exception_ptr` needs the hooks of the patched `libC.a` (submodule `3rd/edg`); without them the test reports SKIP | ci.yml, pathb.yml |
| CUDA source (`.cu`, `tools/cuda-rewrite`, `tools/pathb-ptx-emit`, `lib/cuda/nfcxx_cuda.h`) | Launch rewrite golden files and refusals; device code built and run on the GPU (kernels split into modules, struct ABI against nvcc); `docs/notes/gpu.md`, "CUDA source" | `tests/cuda/run.sh` (needs the CUDA toolkit) | ci.yml: none |
| SYCL (`lib/sycl`, `scripts/sycl-build.sh`, `scripts/pathb-wgsl-emit.rb`, `scripts/pathb-spirv-emit.rb`; `docs/notes/sycl-webgpu.md`, `docs/notes/sycl-vulkan.md`) | A SYCL 2020 subset (on Vulkan too, lavapipe-tested: `--backend=vulkan`) (buffers, accessors, USM, `parallel_for` over range and nd_range, local memory and barriers, atomics, reductions, math) runs as C++ loops on the host or as WGSL kernels through WebGPU, with identical results on 12 test programs; checked operations set a trap flag and the run exits 71; kernels with `double`, library calls or zero-initialized globals are refused (exit 3). WebGPU part needs the Path B harness, the nfcxx build, node, Playwright and a WebGPU adapter (SwiftShader is enough), else it skips (`tests/sycl/run.sh`; `tests/sycl/compat/` for the oneapi-samples sweep, by hand) | pathb.yml |
| Hexagon | Generated C for the `linux_riscv32` stand-in target compiles with clang-19 `--target=hexagon` and runs under qemu-hexagon, HVX kernels included; struct layout equals clang's Hexagon ABI (`tests/hexagon/run.sh`, `tests/hexagon/layout.sh`). Not the Hexagon SDK, QuRT or `hexagon-sim` (unavailable, `docs/notes/hexagon.md` section 4). | hexagon.yml |
| `nfcc` (drop-in `cc`, C only) | `-c`, link, `-S`, `-E`/`-M*` answered by the host compiler, `-D -U -I`, dependency files, response files, `-shared`, rejected options, on both backends (`tests/c/cc-mode.sh`); Lua through its own makefile (`tests/realworld/run_lua_make.sh`); mruby's rake build (`tests/realworld/run_mruby.sh`) | ci.yml, realworld.yml |
| The CUDA driver through libcudart (`--cuda-driver=`, `scripts/cuda-driver-shim`, `lib/cuda/driver`; `docs/notes/cuda-driver.md`) | The driver API through libcudart: the ABI version and stream flag of each call, eleven arguments through the trampoline, failure codes and error strings, one lookup per function, against a stand-in libcudart, built by gcc and by nfcc and nfcxx on both backends; a CMake project linking `CUDA::cuda_driver` with nfcc, by default without libcuda and with `NFCXX_CUDA_DRIVER=libcuda` with it; with the real libcudart 12.9, no libcuda.so.1 needed and `CUDA_ERROR_NO_DEVICE` without a driver, also bundled (`tests/cuda/driver/run.sh`; the stand-in cases with the 12.9 headers only). Run by hand on a GPU with the 12.9, 12.6 and 13.4 toolkits. cuBLAS SGEMM and cuDNN convolution on a GPU through the shim, by gcc, nfcc (gcc backend) and nfcxx (both backends): no libcuda.so.1, `CUDA_ERROR_NO_DEVICE` with the driver hidden, bundled and run in a sandbox without the toolkit (`tests/cuda/gpu/run.sh`, by hand) | cuda.yml (gpu/run.sh: none) |
| `--bundle-libs` (`tools/bundle`, `build/nfcbundle`; `docs/notes/bundle.md`) | The libraries an executable or shared object needs, copied into it, run with the originals out of reach and give the same output: C programs and libraries with TLS in all models, threads, init/fini order, interposition, IFUNC, symbol versions and copy relocations (GNU ld PIE/no-PIE/RELR/lazy, lld PIE/no-PIE); shared object inputs dlopen'ed and linked against; libstdc++ and libgcc_s with exceptions across them (host g++); `--stubs` for plugins that name bundled libraries; `nfcxx --bundle-libs` on both backends, `-shared`, `--bundle-exclude`, `--bundle-stubs`; `nfcc --bundle-libs` (`tests/bundle/run.sh`). libtorch 2.5.1+cu124 built by g++ and by nfcxx (gcc backend), bundled with its CUDA libraries, stubs and the dlopen'ed cuDNN/linalg libraries beside it, without a GPU; libtorch 2.14.1+cu130 on a GPU, built by g++ and by nfcxx (both backends), bundled (`tests/bundle/torch.sh`, by hand) | ci.yml (torch.sh: none) |
| Call ABI of classes against g++ (`docs/notes/call-abi.md`) | Registers or a hidden pointer as g++ chooses, both directions (g++ library and nfcxx caller, nfcxx library and g++ caller), both backends: `std::optional` of an enum, `int`, `long` and `std::string`, C++20 two-constructor classes (constrained default beside user-provided, complementary constraints, move pairs), a member of one, a move-only class with a trivial move constructor (`tests/call-abi/run.sh`) | ci.yml |
| `nfceval` (`lib/eval`) and `nfcxx -shared` | Evaluate snippets with bound objects/functions/methods, errors as exceptions, cache, shared objects, on both backends (`tests/eval/run.sh`) | ci.yml |
| `nfcffi` (`lib/ffi`; `docs/notes/ffi.md`) | Compile C at run time and call its functions through C++ function types: ints, floats, struct arguments and returns (register and hidden-pointer), callbacks into the host, the C library's functions compiled by gcc (`div`, `ldiv`, `qsort`), errors and the cache, on both backends (`tests/ffi/run.sh`); the signatures of the functions in headers, C and C++ dialects, from the libclang-edg front end (`Ffi::declarations`) | ci.yml |
| `nfcpoly` (`lib/poly`, `scripts/setup-poly.sh`, `scripts/setup-poly-lua.sh`, `scripts/setup-poly-js.sh`, `scripts/setup-poly-go.sh`) | Evaluate Ruby, Lua, Python, JavaScript (QuickJS-NG, plain C, `scripts/quickjs-cproc.patch`), Go and `ast` (Lua syntax on the nfcast engine) from C++, alone or together in one `Context`, with bound functions, objects of registered classes and variables; values both ways; script errors as `ScriptError`, host exceptions caught by scripts and rethrown unchanged when unrescued; destructors of C++ frames run when a script raise crosses them (mruby and Lua built with C++ exceptions, the nfcast engine is C++; `docs/notes/poly.md`); GC release of script-owned objects. Go is yaegi in a cgo shared library (`build/poly-go/libnfcgo.so`, one for both back ends) with a statically typed binding model: typed functions, generated wrapper types with methods, bound variables synchronized at the boundaries, no host callbacks from goroutines. `recover()` in scripts gives the plain panic value, `nfc.Go` starts a goroutine whose panic is an error instead of the end of the process. 1206 checks on both backends (`tests/poly/run.sh`; Go alone 318; Python and Go report SKIP when python3-dev, or Go >= 1.24 and the Go module proxy, are missing), the Ruby/Lua/Python/JavaScript binary also under valgrind by hand, the Go one under AddressSanitizer and LeakSanitizer on both back ends (`tests/poly/asan-go.sh`; valgrind only with `tests/poly/valgrind-go.supp`, `poly.md`) | ci.yml (with `actions/setup-go`) |
| `nfcast` (`lib/ast`) | A Lua 5.4 subset on a self-specializing AST interpreter, with the inlining of small script functions at hot call sites (a clone of the callee's body, loops and multiple assignment included, with pure arguments substituted, guarded by the function, run in a frame that looks like a real call's) and a tier that compiles hot numeric kernels and hot numeric loops (on-stack replacement; off by default): 29 programs whose output equals a real Lua 5.4.9's, each with inlining on, as early as possible and off, with the tier compiling every function at its first call (also with early inlining) and with it compiling in the background; 194 checks of the specialization and inlining counters, the guard, tracebacks, collector, host objects and errors and 332 checks of the tier (compiled code and its counters, bailouts, rebinding, error texts, the cache, failed compiles) (`tests/ast/run.sh`, both backends); random-program fuzzing against the reference by hand (`tests/ast/fuzz.sh`, including random small helpers and methods called over changing argument types; `tests/ast/fuzz_tier.sh` for random numeric kernels); speed by hand (`tests/ast/bench.sh` for the inlining, `tests/ast/bench_tier.sh` for the tier). The tier compiles numeric kernels only: no tables, strings, native calls or on-stack replacement. No coroutines, `goto`, `<close>`, `utf8`, `io`/`os` (`docs/notes/ast.md`) | ci.yml |
| `nfcuop` (`lib/uop`; `docs/notes/uop.md`) | UOp graph with static shapes (reshape/permute/expand/shrink/pad/flip, reductions), interning, rewriting and an exact symbolic simplifier checked against the interpreter on random graphs; an ONNX-style graph (`hir`, ONNX opset 18) whose export is accepted by `onnx.checker` and computes the interpreter's results in onnxruntime; a numpy-like `np::Tensor` API over it (broadcasting, slicing, concatenation, reductions, `matmul`, `softmax`, ...), 100 expressions equal to real numpy in shape and values (`tests/uop/run.sh`, both backends; the Python checks need numpy/onnx/onnxruntime and SKIP without). C rendering (fused loop nests compiled with `cc`, bit-identical to the interpreter on ~32,000 random and hand-written comparisons) and configurable default dtypes (32-bit; float64/int64 give numpy's, all 100 expressions equal to numpy in dtype too). Autodiff and the script bindings have their own rows below; no dynamic shapes or ONNX import yet | ci.yml |
| `nfcuop_poly` (`lib/uop/nfcuop_poly.cpp`; `docs/notes/uop-poly.md`) | The numpy-like API from Ruby (mruby), Lua, Python, JavaScript (QuickJS-NG) and Go (yaegi): `np.array/zeros/arange/placeholder/eval/to_onnx/...`, `Tensor` with shape/dtype/T properties, operators `+ - * / % // @ & \| ^ < > ...` on Python, Ruby (right operand) and Lua (arithmetic) with numbers on either side where the language allows it, named methods in all five; one MLP-with-softmax model built in each language gives values equal bit for bit to the C++ API and ONNX bytes identical to the C++ model's, and the operators, `nfcuop::Error` as a script error with its message (and out of `eval` unrescued), dtype configuration and the C backend are checked per language (`tests/uop/run_poly.sh`, run from `tests/uop/run.sh`; 1375 checks on the host g++ in the session that wrote it, the nfcxx back ends not run there). The optional-argument, computed-property and operator-method support it needs is in nfcpoly (`tests/poly/ops.cpp`) | ci.yml |
| `nfcuop` autodiff (`lib/uop/nfcuop_onnxgrad.*`, `scripts/setup-onnxsim.sh`; `docs/notes/uop-autodiff.md`) | `hir::gradients_via_onnxsim` / `np::grad` by onnxsim at the pinned commit `21f95fd1` (C++ library via dlopen; Python fallback still onnxsim 0.8.1) for the operators it has rules for (Add Sub Mul Div Neg Relu Sqrt Exp Log Sigmoid Tanh Clip MatMul Transpose Reshape Identity ReduceSum ReduceMean Softmax Slice Expand Squeeze Unsqueeze Abs Max Min Concat LogSoftmax ReduceMax ReduceMin); 72 finite-difference cases in float64 (max relative error 1.25e-9), equal to the former native gradients to 4e-17 where both exist, second derivatives, C backend bit-identical to the interpreter, gradient models accepted by `onnx.checker` and equal in onnxruntime; tests print SKIP without onnxsim; plus the ONNX reader `Graph::from_onnx` / `merge_onnx` (round trips, models from the onnx package equal to onnxruntime) (`tests/uop/run.sh`). Lost against the native rules: Sin, Cos, comparisons used as masks, Cast to the dtypes its rule refuses, Slice with a non-positive step, 1-D MatMul, Clip bounds | ci.yml |
| AddressSanitizer (`nfcxx -fsanitize=address`; `docs/notes/asan.md`) | Heap/stack/global overflow, use after free, scope and return, double free, alloc/dealloc mismatch and leaks reported with the C++ source line, exceptions and containers clean; Path B and other sanitizers refused; the qbe default and gcc are instrumented (`tests/asan/run.sh`) | ci.yml |
| Safe pointers (`nfcxx -fsafe-pointers`; `docs/notes/safe-pointers.md`) | Out-of-bounds accesses, pointer arithmetic that leaves its object, use after free (also after heavy churn), use after return, double free, calls of the wrong type and of data, each reported with the C++ source line; correct programs (containers, exceptions, threads) run clean, and the Path B probes give the same results with and without the flag (`SAFEPTR_SWEEP=1 tests/safeptr/run.sh`) | pathb.yml |
| Tracing (`--trace=FILE`, `NFCXX_TRACE`) | Valid trace-event JSON with the driver and backend spans, both backends, exit code unchanged (`tests/trace/run.sh`, needs python3) | ci.yml |
| mruby scripting (`scripts/mrb`, `*.rb`) | Every ported script gives output byte-identical to its Python original (`tests/mruby/run.sh`; Path B and Hexagon parts need the harness and a clang with the Hexagon target, else they skip) | ci.yml (Path A parts), pathb.yml (with the harness) |

Every `tests/*/run.sh` and `tests/realworld/*.sh` is wired into a workflow, with these exceptions:
`tests/builtins/fe_matrix.sh` prints a table (EDG acceptance of each builtin in three dialects) and has no pass/fail,
`tests/bundle/torch.sh` needs a 2.5 GB libtorch download (run by hand, `docs/notes/bundle.md`), `tests/cuda/gpu/run.sh`
needs a GPU (run by hand, `docs/notes/cuda-driver.md`),
and `tests/mruby/qbe-prep.sh` and `qbe-prep-tap.sh` are run by `tests/mruby/run.sh`, and `tests/uop/run_poly.sh` by `tests/uop/run.sh`. `tests/realworld/*.sh` clone
upstream sources at pinned commits and report SKIP (exit 0) when the fetch fails, so an unreachable GitHub shows up as a
SKIP line in the log, not as a red job.

## Known limitations, in one place

Each entry names where it comes from and what, if anything, checks it.

**C++ modules** (`docs/notes/modules.md`)
- Standard headers in the global module fragment (`module; #include <cstdio>`) make the interface compile fail: the IFC writer dumps the whole global scope, including the declarations of the included headers. `tests/modules/run.sh` does not cover it.
- A union type cannot be read back by an importer ("invalid combination of type specifiers"); the writer now writes it. Not covered by a test.
- `import std;` and header units are refused with a message (no standard library module yet).

**`long double`**
- Path A qbe: cproc rejects it ("long double is not yet supported"). `tests/realworld/run_doctest.sh` therefore
  runs doctest on gcc only and reports a SKIP for qbe (`docs/notes/realworld.md`).
- Path B: supported (`docs/notes/pathb-longdouble.md`). A `long double` is a 16-byte object in the x86-64 layout, every operation is a
  call of a helper in `be/nfcxx_ldrt.c` (gcc, x87), results in `st(0)` go through generated assembly thunks, so libc, libm
  and libstdc++.so are called directly. Checked by `tests/pathb-qbe/cases/longdouble_*.cpp`, `multi/abi_ld`, the traps
  `traps/longdouble_*.cpp` (all in `tests/pathb-qbe/run.sh`), the IR golden `tests/pathb-ir/longdouble_ir.ir` and the thunk
  edge cases `tests/mruby/pathb-edge/x87_thunks.ir` (`tests/mruby/run.sh`, Python oracle identical). Named limits: variadic
  functions returning `long double` as pointer targets, unions of at most 16 bytes holding a `long double`; `std::format` builds
  (`_Float128` is supported, `pathb-float128.md`); see the note, section 7. The option
  `--long-double=trap` remains for hand-written IR that still mentions the scalar type
  (`tests/mruby/pathb-edge/r_longdouble.ir`).
- Hexagon: EDG's `long double` is 16 bytes, Hexagon's is 8; `tests/hexagon/layout.sh` leaves it out (`hexagon.md`).

**`_Complex`**: unsupported by cproc ("_Complex is not yet supported"), so by Path A qbe and by `nfcc` on qbe
(`realworld.md`, "What remains"; the mruby gem `mruby-cmath` is the case). No test asserts it; checked by hand with a
one-line `.c` file (qbe fails, gcc backend runs it). Path B has no `_Complex` handling (`ck_complex` is listed as not covered in `pathb-stage1.md`).

**Exceptions**
- EDG lowers C++ exceptions to its own setjmp/longjmp ABI and runtime (`libC.a`). Such a program runs on Path A
  (`tests/cases/exceptions.cpp`) and Path B (`tests/pathb-qbe/cases/eh_*.cpp`), with no zero-cost unwinding: every
  function with a handler keeps all its slots in memory (`pathb-stage3.md`, "C++ exceptions", Limits).
- Exceptions thrown by libstdc++ through its `std::__throw_*` functions (`std::string::at`, `vector::at`, `std::stoi`, empty
  `std::function`, ...) and `std::exception_ptr` work: the driver links `lib/ehshim`, a shim that throws them with EDG's runtime
  (`eh-shim.md`; `tests/cases/eh_libstdcxx_throw.cpp`, `tests/cases/eh_exception_ptr.cpp`, `tests/ehshim/run.sh`). What is left: libstdc++
  EDG's `longjmp` skips the destructors of gcc-compiled frames (unless `NFCXX_EH_UNWIND=1`), the EH runtime is not thread safe
  (`eh-shim.md`, "Limits"). A plain `throw` of gcc-compiled code (libtorch's `c10::Error`) reaches EDG's handlers too
  (`__cxa_throw` in the shim).
- An exception cannot unwind across a shared-object boundary (each object has its own EH stack): `nfceval` catches inside
  the snippet and rethrows a `RuntimeError` in the host (`tests/eval/run.sh`).
- Hexagon EH runtime: multiple/virtual-base catch matching, `noexcept` violations, array `new` unwinding and thrown
  `double`/`float` are not supported (`hexagon.md`, section 3a). No test asserts the failures.
- Path B and Path A alike catch exceptions thrown inside libstdc++.so through the shim above (`vector::at`, `std::__throw_*`). Before
  it they aborted (the gcc unwinder); `new` of a huge size on the gcc backend too (libstdc++'s `operator new`; the driver now links `libC.a`
  first). User-code throws and `std::runtime_error` constructed in user code work (`tests/pathb-qbe/cases/hosted_stdexcept.cpp`, `eh_std.cpp`).

**Variable-length arrays (Path B)**: storage is EDG's `__vla_alloc`/`__vla_dealloc` pool in `libC.a`, a single global that
is not thread safe, costing two calls and a `malloc` per VLA; subscripts of the VLA variable are bounds-checked (abort)
against the run-time count, except through a run-time inner dimension or a pointer (`pathb-stage2.md` 5b, `pathb-hosted.md`;
`tests/pathb-qbe/cases/vla_bounds.cpp`, `traps/vla_index.cpp`). Scope exit is checked single-threaded by `tests/pathb-qbe/cases/vla_scope.cpp`.


**Inline asm**: Path A qbe handles only `__asm__ volatile("int $3")` (`tests/cases/qbe_int3_break.cpp`); Path B accepts empty
barriers, nops/`pause`, fences (`mfence`, `lfence`, `sfence`, `lock; addl`), `ud2`, `int $3`, `rdtsc` with `"=a"`/`"=d"` outputs and an
empty template with operands as a value passthrough (`tests/pathb-qbe/cases/asm_barrier.cpp`, `asm_ext.cpp`, `traps/asm_ud2.cpp`), and
refuses any other instruction, a register clobber or `goto` (`tests/mruby/pathb-edge/r_unsupported_asm*.ir`,
`tests/pathb-ir/gaps.cpp`); list in `pathb-hosted.md`, "Inline asm". The gcc backend passes asm through.

**`volatile`**
- Path A qbe: for EDG-generated C, cproc rejects stores to `volatile` objects ("volatile store is not yet supported").
  `qbe-prep` drops the qualifier only for hand-written `.c` inputs (`NFCXX_C_INPUT`) and keeps volatile locals in memory
  (`tests/c/volatile_setjmp.c`; `realworld.md`, "C inputs"). Not covered: volatile function parameters and `for`
  declarations.
- Path B: every volatile access is a call of a module-local helper, so volatile code is slow; not atomic, not a fence
  (`tests/pathb-qbe/cases/volatile.cpp`, with assembly checks `// ASM-COUNT:`).

**Path B other**: checked (`NFCXX_IR_OVERFLOW=trap`) unsigned or 64-bit signed multiplication is refused; pointer subscripts are not bounds-checked and there is no `undef` (by decision); thread-local
objects are x86-64 ELF only and a thread-local address in a static initializer is refused; only LP64 layouts are emitted
(`pathb-stage3.md`; refusal paths: `tests/mruby/pathb-edge/r_*.ir` via `tests/mruby/run.sh`). Hosted headers now work (`pathb-hosted.md`; `PATHB_HOSTED=0` or
`--freestanding` gives the old EDG-only headers). Still failing there: asm outside the list in
`pathb-hosted.md` ("Known limits"; no test asserts the failures). `__builtin_object_size` answers only for the address of a known
object (else -1/0), TYPE 1 for a member of a global structure is answered when unambiguous and -1 otherwise (`builtin_objsize.cpp`, `builtin_objsize_global.cpp`); `alias`/`weakref` need a target defined in
the unit and x86-64 ELF (`alias_attr.cpp`, `alias_static.cpp`). `__builtin_trap` is SIGILL on Path B (`traps/builtin_trap.cpp`).

**cproc / qbe backend, other**
- `alignas(16) int x;` on a block-scope local becomes `__attribute__((aligned))`, which cproc rejects ("GNU attribute
  'aligned' is not supported here"); the gcc backend accepts it. Two shapes from libstdc++ are rewritten by `qbe-prep`
  (`realworld.md`). No test asserts the rejection; `tests/lib/new_launder.cpp` uses a union to avoid it
  (`freestanding.md`). Checked by hand with a one-line program on both backends.
- `__builtin_trap` is unknown to cproc (`tests/builtins/trap_compile_only.cpp`, `XFAIL-qbe`); `freestanding.md`'s `panic` uses `abort`.
- `va_arg` of an aggregate works only for integer-class aggregates of at most 16 bytes (`cproc-vaarg-aggregate` (a commit on take-cheeze/cproc branch nfcxx-asan-combined),
  `tests/c/va_struct.c`); floats in the aggregate, larger or over-aligned ones still stop with cproc's error (`realworld.md`).
- Empty classes have size 0 in the C that cproc sees, while EDG folds `sizeof` as 1 (`freestanding.md`; no test asserts it).
- `nfcc` on qbe ignores `-O*` and `-g*` (no optimisation levels, no debug info); `-Wp,` items outside the listed
  preprocessor options are rejected (`tests/c/cc-mode.sh`, `realworld.md`).
- qbe-compiled mruby uses the portable `switch` dispatch, not computed goto (`realworld.md`; `tests/realworld/run_mruby.sh`);
  so does QuickJS (`scripts/quickjs-cproc.patch`, `poly.md`).
- `-D_GNU_SOURCE` plus `#include <stdlib.h>` or `<math.h>` used to fail on qbe with `declaration has no type specifier`.
  glibc declares `strtof32x`, `acosf32x` and friends with `_Float32x` and `_Float64x`. `qbe-prep` now maps `_Float32x` to
  `double`, `_Float64x` to `long double` and `_Float128x` to the 16-byte `_Float128` struct, and the `f32x`/`f64x`/`f128x`
  literal suffixes follow them. Regression case: `tests/cases/qbe_floatnx_gnu_source.cpp`.
- QuickJS needed three more constructs that cproc rejects, patched in the throwaway checkout (`scripts/quickjs-cproc.patch`):
  `_Atomic` (`quickjs-c-atomics.h`, replaced by libatomic's sized functions chosen with `_Generic`; `Atomics` results are checked
  for every element size by `tests/poly/run.sh`), `return f();` of a `void` call inside a `void` function, and the spelling
  `__attribute((...))`.

**Driver**: `nfcxx --emit-c` does not pass user `-I` options to `cpfe` (`realworld.md`; no test). Tracing uses GNU `date`
(Linux only) and does not time EDG's front end separately inside `eccp` (`tracing.md`; `tests/trace/run.sh` checks the
spans that exist).

**`--bundle-libs`** (`bundle.md`, "Limitations"; `tests/bundle/run.sh` covers the supported cases, not the limits): x86-64
only; without `--stubs`, a plugin that names a bundled library in its own `DT_NEEDED` loads a second copy (with them,
`dlsym` on such a handle finds nothing); libraries loaded only by `dlopen` stay files; at most 4 GiB of units; no lazy binding; `LD_PRELOAD` does not interpose calls between bundled units of an executable; TLS
descriptors and executables with pre-2.34 glibc startup code are refused.

**`nfceval`** (`eval.md`, "Limitations"; `tests/eval/run.sh` covers the supported forms, not the limits): no sandbox
and no run-time timeout; one eval at a time per engine, not thread safe; no overloaded bindings, no generic lambdas or
C varargs as bound functions; host and snippet must use the same backend.

**`nfcpoly`** (`poly.md`, "Limitations"; `tests/poly/run.sh` covers the supported forms, not the limits): no sandbox and no
time limit (Go: a whitelist of standard packages, no files or processes unless bound; an endless loop still hangs); not thread safe; constness and inheritance of bound classes are not tracked; a libmruby built without
`enable_cxx_exception` links but loses the destructor guarantee (measured, not part of the suite); the mruby build
needs `scripts/mruby-cxx-novolatile.patch` because cproc cannot store to a `volatile` (see **`volatile`** above) and
`MRB_USE_VM_SWITCH_DISPATCH` because EDG rejects mruby's computed-goto table when `vm.c` is compiled as C++; Path B
untested; no compile-time embedding. Lua needs `scripts/lua-cxx-novolatile.patch` for the same `volatile` reason and
opens only the base (without `dofile`/`loadfile`), coroutine, table, string, math and utf8 libraries. Python is the system
CPython (`python3-config`, tested with 3.12 only; the suite skips it when the headers are missing), one interpreter per process that is
never finalized, and a write through `global` in a function shadows a bound variable. JavaScript is QuickJS-NG v0.17.0 compiled as
plain C (no C++ build) with `scripts/quickjs-cproc.patch`; a script has no modules, files, timers or `console`, a script error is
any thrown value (a non-error is class `Error`), a number is an integer when it is whole and a safe integer, promise jobs run when
the outermost call returns; the library is built with QuickJS's asserts on, so a `JSValue` leaked through the raw API aborts when
the `Context` closes (untested). Go is yaegi v0.16.1 (pinned in `lib/poly/go/go.mod`)
in a 30 MB cgo shared library that needs Go >= 1.24, cgo and the Go module proxy to build (the suite skips Go otherwise): it is a Go
interpreter with gaps (`poly.md`, "Speed and coverage gaps", each asserted by `tests/poly/host.cpp`), compile errors are `SyntaxError`,
bound variables are synchronized only at the boundaries of an evaluation and of a host call, a host function called from a goroutine
of the script panics (`GoroutineError`) and a panic that a script goroutine does not recover ends the process, `Value::call` does not
reach methods of types the script defines, and valgrind is not usable with the Go runtime loaded (3800 reports from the runtime and
yaegi, none a bad free).

**`nfcast`** (`ast.md`, "The language"; `tests/ast/run.sh` covers the supported forms): no sandbox and no time limit; the evaluator recurses on the C++ stack
(1500 nested script calls, `State::max_depth`; tail calls are not eliminated); no coroutines, `goto`, `<close>`, `__gc`, weak tables,
`utf8`, `string.pack`, `io`, `os`; speed is 0.8x to 2.4x of PUC Lua's time (one measurement with the host compiler, `ast.md`). The tier
(off by default) compiles only numeric kernels (no tables, strings, calls of native functions; a loop that runs in a function called
once is not replaced while it runs) and needs the nfcxx driver at run time. The inlining of small functions (`ast.md`, "Inlining") saves
17% to 25% of the instructions in a loop made of small calls (wall time within the noise of a shared machine, up to 1.7x on the
nfcxx back ends against inlining off) and 1% to 3% for a recursive function; it leaves callees with closures or `...` as calls
(loops and multiple assignment are inlined, except loops when the tier is on), inlines method calls on tables only, inlines a site
again after a guard failure at most three times, and does not inline host functions
(the C compiler does that for ordinary C++, not for functions registered as type-erased callables).
**Hexagon**: no Hexagon SDK, `hexagon-sim` or QuRT; EDG has no Hexagon target, so a 32-bit little-endian stand-in
(`linux_riscv32`) is used; cases that include hosted C++ headers, need GP-relative relocations or template instantiation
(`edg_prelink`) are reported as SKIP by `tests/hexagon/run.sh` (`hexagon.md`).

**Test inputs**: `tests/realworld/*.sh` fetch pinned upstream commits and need network access (SKIP when the fetch fails).
