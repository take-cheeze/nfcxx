# nfcxx

Experimental C++ compiler built on the EDG front end (Apache 2.0). See `docs/DESIGN.md`; `docs/README.md`
indexes the notes and gives the current status and known limitations, test by test.

```
git submodule update --init --depth 1   # fetch 3rd/edg
scripts/setup-edg.sh      # build EDG (3rd/edg submodule) into build/edg (~3 min)
scripts/setup-qbe.sh      # build QBE + cproc (3rd/qbe, 3rd/cproc) into build/
scripts/setup-mruby.sh    # the mruby interpreter that runs the helper scripts (needs ruby + rake once); built on first use otherwise
./nfcxx hello.cpp -o hello   # C++ -> C -> cproc -> QBE -> asm (default backend)
./nfcxx --backend=gcc ...    # C++ -> C -> gcc -O2 -fwrapv -fno-strict-aliasing
./nfcxx --emit-c hello.cpp   # print the generated C
./nfcxx -fsanitize=address x.cpp -o x # AddressSanitizer via the gcc backend (docs/notes/asan.md); tests/asan/run.sh
./nfcxx --trace=t.json x.cpp # Chrome/Perfetto trace of the driver steps (docs/notes/tracing.md)
./nfcc -c x.c -o x.o         # drop-in cc for C, for make/rake/autoconf (docs/notes/realworld.md)
tests/run.sh              # regression cases in tests/cases (// EXPECT: <exit code>); C++17 evaluation order: docs/notes/eval-order.md
./nfcxx --freestanding x.cpp # headers from lib/ only, no hosted libc++/libstdc++ (docs/notes/freestanding.md)
tests/lib/run.sh          # freestanding library tests (both backends)
tests/builtins/run.sh     # compiler builtin probes (docs/notes/builtins.md)
./nfcxx -shared x.cpp -o x.so # shared object; lib/eval/ evaluates C++ snippets at run time (docs/notes/eval.md)
tests/eval/run.sh         # nfceval library and -shared (both backends)
scripts/setup-poly.sh     # mruby built with C++ exceptions for lib/poly (NFCXX_BACKEND=qbe|gcc; needs ruby + rake once)
scripts/setup-poly-lua.sh # Lua 5.4 built with C++ exceptions for lib/poly (Python uses the system python3-dev)
scripts/setup-poly-js.sh  # QuickJS-NG (plain C, patched for cproc) for lib/poly
tests/poly/run.sh         # nfcpoly: evaluate Ruby, Lua, Python, JavaScript and ast from C++ with bound host objects, exceptions across the boundary (both backends; docs/notes/poly.md)
tests/ast/run.sh          # nfcast (lib/ast): the self-specializing AST interpreter with inlining of small functions and a tier for hot numeric kernels, checked against a real Lua 5.4 (both backends; docs/notes/ast.md)
scripts/setup-pathb.sh    # Path B harness (own back end on EDG's IL); then tests/pathb{,-ir,-qbe}/run.sh (docs/notes/pathb-stage3.md)
./nfcxx -c a.cpp -o a.o; ./nfcxx a.o b.o -o x # separate compilation (docs/notes/multi-tu.md)
tests/multi-tu/run.sh     # several translation units sharing libstdc++ templates (both backends)
tests/ehshim/run.sh       # exceptions thrown by libstdc++ and std::exception_ptr (lib/ehshim, docs/notes/eh-shim.md)
```

Which workflow runs which test script: `docs/README.md`, "Status matrix".
