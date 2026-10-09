# nfcxx

Experimental C++ compiler built on the EDG front end (Apache 2.0). See `docs/DESIGN.md`.

```
git submodule update --init --depth 1   # fetch 3rd/edg
scripts/setup-edg.sh      # build EDG (3rd/edg submodule) into build/edg (~3 min)
scripts/setup-qbe.sh      # build QBE + cproc (3rd/qbe, 3rd/cproc) into build/
./nfcxx hello.cpp -o hello   # C++ -> C -> cproc -> QBE -> asm (default backend)
./nfcxx --backend=gcc ...    # C++ -> C -> gcc -O2 -fwrapv -fno-strict-aliasing
./nfcxx --emit-c hello.cpp   # print the generated C
tests/run.sh              # regression cases in tests/cases (// EXPECT: <exit code>)
./nfcxx --freestanding x.cpp # headers from lib/ only, no hosted libc++/libstdc++ (docs/notes/freestanding.md)
tests/lib/run.sh          # freestanding library tests (both backends)
tests/builtins/run.sh     # compiler builtin probes (docs/notes/builtins.md)
```
