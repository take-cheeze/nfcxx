# Cpp2 (cppfront) inputs: experimental

Status: **experimental.** `nfcxx file.cpp2 -o prog` translates a Cpp2 source with cppfront and builds the result through
the usual C++ pipeline (EDG, then the qbe or gcc backend). The pieces are in place and `tests/cpp2/run.sh` (5 cases)
passes. Most of cppfront's own regression suite does not build yet, because EDG rejects the C++ that cppfront's
runtime header generates. The sweep numbers are below.

## Pipeline

```
prog.cpp2 --build/cppfront -q -o DIR/prog.cpp (run in a scratch directory)--> prog.cpp
prog.cpp + -I DIR-of-prog.cpp2 + -I 3rd-or-build/cppfront-src/include (cpp2util.h) --> the C++ pipeline
```

- `scripts/setup-cppfront.sh` shallow-clones hsutter/cppfront at the pinned commit `66eb614` (v0.8.2, from
  `source/version.info`) into `build/cppfront-src` and builds `build/cppfront` with `$CXX -std=c++20 -O2`. The pin is
  not a submodule: a fresh checkout and CI do not fetch cppfront unless a `.cpp2` build asks for it.
  `CPPFRONT_SRC=DIR` uses a checkout instead of the clone; `CPPFRONT_REPO=URL` names another remote.
- The driver's `cpp2_prepare` (next to `cu_prepare` in `nfcxx`) translates each `.cpp2` input. The copy keeps the source's
  basename, so default object and output names are unchanged, and its `#line` directives name the `.cpp2` file, so
  errors point at the Cpp2 source.
- `-c` keeps the translation in `${NFCXX_CU_CACHE:-~/.cache/nfcxx}/cpp2/KEY`, keyed by the absolute object path, because the
  prelinker re-reads the translated source at link time (the same rule as `.cu` inputs). Otherwise it lives in the
  driver's temp directory, which the EXIT trap removes.
- A `.cpp2` input is not object-cached (`NFCXX_CACHE`), as `.cu` inputs are not.
- `-I DIR-of-prog.cpp2` is added, so quoted includes next to the Cpp2 file are found; the translation is elsewhere.

## Limits

- **cppfront writes `cpp2_post_build.sh` into its working directory on every run.** The driver runs it in a scratch
  directory. The build steps that file would hold (from metaclasses' `add_extra_build_step`) are not run.
- A Cpp2 declaration without a body is not Cpp2 (cppfront rejects it). A C++ function is called from Cpp2 through a
  header, as `tests/cpp2/run.sh` case 3 does.
- The translation is not a stable interface: `CPPFRONT_SRC` and the pin must match the cppfront the sources were written
  for. The driver does not check the version.
- `--emit-c` works on a `.cpp2` input (checked on the hello sample). Preprocessing and dependency options (`-E`, `-MD`)
  have not been checked on `.cpp2` inputs.

## Main blocker: EDG and cpp2util's UFCS lambda

cppfront's generated code calls member functions with UFCS (`x.f(...)` written as `f(x, ...)`), which `cpp2util.h`
implements with the `CPP2_UFCS` macro: a generic lambda over `Obj&&` and `Params&&...` whose `requires`/`noexcept`
expressions use `std::declval`. EDG rejects the call, for example `pop_back(v)` on a `std::vector`:

```cpp
#include "cpp2util.h"   // cppfront v0.8.2 include/
#include <vector>
int main() {
    std::vector<int> v{1, 2, 3};
    CPP2_UFCS(pop_back)(v);   // EDG: "no instance of function template "lambda [](Obj &&, Params &&...)->decltype(auto)" matches the argument list"
}
```

g++ 13 and clang++ accept it, and so do the translations of the failing samples (checked with `-fsyntax-only` on
`mixed-bounds-check` and `mixed-autodiff-taylor`). So the fault is in EDG's overload resolution for this lambda, not in
the translation. This is the item to report upstream (EDG) or to work around in `cpp2util.h` (the Cpp2 side), and it
accounts for every failure in the sweep below except the one at the end.

Repro used: the six lines above, in `/home/user/hsutter/cppfront` (clone), built with `nfcxx -I .../include`.

## Sweep: cppfront's regression suite through nfcxx

`regression-tests/*.cpp2` at the pin, excluding names with `error`, `bad` or `fail` (160 files). Each was compiled with
`nfcxx FILE.cpp2 -o OUT` on the qbe backend; no run-time check of the output.

Not yet complete: 41 of 160 at the time of this commit (25 pass, 5 fail, 11 fail in EDG on the UFCS lambda). The totals will be
recorded here when the run finishes.

## Tests

`tests/cpp2/run.sh` (5 cases): a Cpp2 program builds and prints; `-c` then link; a `.cpp2` and a `.cpp` in one command;
a quoted include next to the Cpp2 file; a Cpp2 syntax error fails the build and names the `.cpp2` file. It needs
`build/cppfront` (`scripts/setup-cppfront.sh`). It is not in CI.
