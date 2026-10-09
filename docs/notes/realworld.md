# Real-world programs

First real third-party project: [tinyxml2](https://github.com/leethomason/tinyxml2) (zlib license),
pinned to commit `8224e427`. `tests/realworld/run.sh` fetches it into `build/realworld` (not vendored)
and builds it with `tinyxml2_main.cpp`, expecting exit code 12.

## Result

- **gcc backend: passes.** The whole library (`tinyxml2.cpp`, 3k lines) compiles and the driver runs
  correctly.
- **QBE backend: passes.** Two things had to work: empty struct definitions (the cproc patch, see
  `docs/notes/freestanding.md`) and COMDAT functions. EDG marks inline and template instantiations
  `__attribute__((__weak__))`; cproc drops that, so the per-object copies collided at link time.
  `scripts/weak-symbols.py` emits `.weak` directives for them in the QBE wrapper.

## What it took

- **Hosted headers:** tinyxml2 includes `<cctype>`, `<cstdio>`, `<string.h>`, and similar. The driver
  now adds the host C++ library include directories and the host GNU version by default
  (`host_sys_includes` in `nfcxx`). `--freestanding` still turns this off. `NFCXX_CXX` picks the host
  compiler and `NFCXX_SYS_INCLUDES` overrides the list.
- **Nothing else** was needed for this library on the gcc backend.

## Next candidates

Projects with no dependencies and their own tests, to find the next gaps: a JSON or XML parser,
a small compression library in C++, or doctest (a single-header test framework).
mruby is C, so it needs a C front-end mode first, which nfcxx does not have yet.
