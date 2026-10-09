# nfcxx

Experimental C++ compiler built on the EDG front end (Apache 2.0). See `docs/DESIGN.md`.

```
scripts/setup-edg.sh      # clone + build EDG into third_party/edg (~3 min)
./nfcxx hello.cpp -o hello   # C++ -> C -> host cc (-O2 -fwrapv -fno-strict-aliasing)
./nfcxx --emit-c hello.cpp   # print the generated C
tests/run.sh              # regression cases in tests/cases (// EXPECT: <exit code>)
```
