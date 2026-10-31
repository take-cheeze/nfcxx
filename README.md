# nfcxx

Experimental C++ compiler built on the EDG front end (Apache 2.0). See `docs/DESIGN.md`; `docs/README.md`
indexes the notes and gives the current status and known limitations, test by test.

```
git submodule update --init --depth 1   # fetch 3rd/edg
scripts/setup-edg.sh      # build EDG (3rd/edg submodule) into build/edg (~3 min)
scripts/setup-qbe.sh      # build QBE + cproc (3rd/qbe, 3rd/cproc) into build/
scripts/setup-mruby.sh    # the mruby interpreter that runs the helper scripts (needs ruby + rake once); built on first use otherwise
scripts/setup-cppfront.sh # cppfront v0.8.2 (Cpp2 to C++1) into build/, for .cpp2 inputs (experimental; docs/notes/cpp2.md)
./nfcxx hello.cpp2 -o hello  # Cpp2: cppfront translates it, then the C++ pipeline above (experimental)
tests/cpp2/run.sh         # Cpp2 inputs: build, -c and link, mixed with .cpp, includes, a syntax error (experimental)
./nfcxx hello.cpp -o hello   # C++ -> C -> cproc -> QBE -> asm (default backend)
./nfcxx --backend=gcc ...    # C++ -> C -> gcc -O2 -fwrapv -fno-strict-aliasing
./nfcxx --emit-c hello.cpp   # print the generated C
./nfcxx -fsanitize=address x.cpp -o x # AddressSanitizer via the gcc backend (docs/notes/asan.md); tests/asan/run.sh
./nfcxx -fsafe-pointers x.cpp -o x # Fil-C-style pointer checks on Path B, prototype (docs/notes/safe-pointers.md); tests/safeptr/run.sh
./nfcxx --trace=t.json x.cpp # Chrome/Perfetto trace of the driver steps (docs/notes/tracing.md)
./nfcc -c x.c -o x.o         # drop-in cc for C, for make/rake/autoconf (docs/notes/realworld.md)
tests/run.sh              # regression cases in tests/cases (// EXPECT: <exit code>); C++17 evaluation order: docs/notes/eval-order.md
./nfcxx x.cpp # GNU extended inline asm (__asm__) on the qbe backend: lowered to out-of-line thunks, x86_64 (docs/notes/inline-asm.md); tests/c/inline_asm_*.c
./nfcxx --freestanding x.cpp # headers from lib/ only, no hosted libc++/libstdc++ (docs/notes/freestanding.md)
tests/lib/run.sh          # freestanding library tests (both backends)
tests/builtins/run.sh     # compiler builtin probes (docs/notes/builtins.md)
./nfcxx -shared x.cpp -o x.so # shared object; lib/eval/ evaluates C++ snippets at run time (docs/notes/eval.md)
tests/eval/run.sh         # nfceval library and -shared (both backends)
tests/ffi/run.sh          # nfcffi (lib/ffi): C compiled at run time, called through C++ function types (docs/notes/ffi.md)
./nfcxx --bundle-libs x.cpp -o x # copy libstdc++, libgcc_s and the program's own .so files into x (also -shared, nfcc; docs/notes/bundle.md)
tests/bundle/run.sh       # nfcbundle: bundled executables and shared objects run without their libraries (both backends)
LIBTORCH=dir tests/bundle/torch.sh # libtorch with CUDA bundled into one 2.4 GB program, plugins through --bundle-stubs (by hand)
./nfcc app.c -lcuda -o app   # -lcuda (or CMake's CUDA::cuda_driver) goes through libcudart: no libcuda.so.1 to link or start (docs/notes/cuda-driver.md)
tests/cuda/driver/run.sh  # the driver shim against a stand-in libcudart and the real one (needs CUDA_HOME headers)
scripts/setup-poly.sh     # mruby built with C++ exceptions for lib/poly (NFCXX_BACKEND=qbe|gcc; needs ruby + rake once)
scripts/setup-poly-lua.sh # Lua 5.4 built with C++ exceptions for lib/poly (Python uses the system python3-dev)
scripts/setup-poly-js.sh  # QuickJS-NG (plain C, patched for cproc) for lib/poly
scripts/setup-poly-go.sh  # yaegi, a Go interpreter, in a cgo shared library for lib/poly (needs Go >= 1.24 and the Go module proxy; one library for both back ends)
tests/poly/run.sh         # nfcpoly: evaluate Ruby, Lua, Python, JavaScript, Go and ast from C++ with bound host objects, exceptions across the boundary (both backends; docs/notes/poly.md)
tests/ast/run.sh          # nfcast (lib/ast): the self-specializing AST interpreter with inlining of small functions and a tier for hot numeric kernels, checked against a real Lua 5.4 (both backends; docs/notes/ast.md)
scripts/sycl-build.sh prog.cpp -o prog  # SYCL 2020 subset (lib/sycl): kernels to WGSL, run through WebGPU; --cpu for plain loops (docs/notes/sycl-webgpu.md)
tests/sycl/run.sh         # SYCL programs on the host path and on WebGPU (Chromium/SwiftShader through Playwright), traps and refusals
scripts/linux-qemu.sh     # minimal x86_64 Linux 6.8 (tinyconfig) + busybox initramfs, booted under qemu-system-x86_64; KCC=nfcc builds it with nfcc (docs/notes/linux-kernel.md)
./nfcxx --cosmo hello.c -o hello.com # Cosmopolitan: cosmocc (APE binary, runs on several OSes) via scripts/setup-cosmo.sh; C only so far (docs/notes/cosmo.md)
scripts/setup-pathb.sh    # Path B harness (own back end on EDG's IL); then tests/pathb{,-ir,-qbe}/run.sh (docs/notes/pathb-stage3.md)
./nfcxx -c a.cpp -o a.o; ./nfcxx a.o b.o -o x # separate compilation (docs/notes/multi-tu.md)
tests/multi-tu/run.sh     # several translation units sharing libstdc++ templates (both backends)
tests/ehshim/run.sh       # exceptions thrown by libstdc++ and std::exception_ptr (lib/ehshim, docs/notes/eh-shim.md)
scripts/setup-sqlite.sh    # SQLite 3.54.1 built with nfcc into build/sqlite (docs/notes/sqlite.md)
tests/sqlite/run.sh       # lib/sqlcache (a TTL key-value cache on SQLite) built with nfcxx on both backends
scripts/setup-libclang-edg.sh # libclang's C API on the EDG front end: cpfe that lists declarations (docs/notes/libclang-edg.md)
scripts/build-libclang-edg.sh # build/libclang-edg/libclang-edg.so, a libclang-compatible shared library
tests/libclang-edg/run.sh # the library against the system libclang, through the C API and clang.cindex
```

Which workflow runs which test script: `docs/README.md`, "Status matrix".

License: nfcxx is MIT (`LICENSE`). Third-party code under `3rd/` and the SQLite bundle keeps its own license.
