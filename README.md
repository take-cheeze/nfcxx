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
./nfcxx --trace=t.json x.cpp # Chrome/Perfetto trace of the driver steps (docs/notes/tracing.md)
./nfcc -c x.c -o x.o         # drop-in cc for C, for make/rake/autoconf (docs/notes/realworld.md)
tests/run.sh              # regression cases in tests/cases (// EXPECT: <exit code>)
./nfcxx --freestanding x.cpp # headers from lib/ only, no hosted libc++/libstdc++ (docs/notes/freestanding.md)
tests/lib/run.sh          # freestanding library tests (both backends)
tests/builtins/run.sh     # compiler builtin probes (docs/notes/builtins.md)
./nfcxx -shared x.cpp -o x.so # shared object; lib/eval/ evaluates C++ snippets at run time (docs/notes/eval.md)
tests/eval/run.sh         # nfceval library and -shared (both backends)
scripts/setup-pathb.sh    # Path B harness (own back end on EDG's IL); then tests/pathb{,-ir,-qbe}/run.sh (docs/notes/pathb-stage3.md)
./nfcxx -c a.cpp -o a.o; ./nfcxx a.o b.o -o x # separate compilation (docs/notes/multi-tu.md)
tests/multi-tu/run.sh     # several translation units sharing libstdc++ templates (both backends)
```

Which workflow runs which test script: `docs/README.md`, "Status matrix".
