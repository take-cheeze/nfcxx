# nfcxx design

Experimental, lightweight C++ compiler. Goals: no LLVM build, host + Hexagon DSP + GPU targets,
UB-free by construction (with a path to Lean proofs), minimal API-compatible standard library.

## Pipeline

```
C++ --EDG front end--+--> Path A: EDG C back end -> C -> host cc            (implemented, host)
                     |                                 -> Hexagon SDK clang (planned)
                     +--> Path B: EDG IL -> own mid-level IR -> QBE / C+HVX / SPIR-V,WGSL (planned)
```

Path A is what `./nfcxx` does today. Path B is the long-term design: structured control flow,
explicit address spaces, explicit safety checks inserted when lowering from EDG's IL.

## Findings so far (answers to the handoff's open questions)

- **EDG builds with GCC 13** (~3 min on 4 cores), after dropping `-Wno-error=return-mismatch`
  (a GCC 14 flag) from `bases/docker/dev-env/gcc/edg_eccp_config`. `scripts/setup-edg.sh` does this.
  Cross-target runtime libs (aarch64, armv7, ...) fail without 32-bit headers; only host `libC.a` is needed.
- **Tools**: `eccp` (driver: cpfe -> gcc -> `edg_prelink` -> link), `cpfe` (front end), `edg_prelink`
  (template instantiation via `.ti` files), `libC.a` (runtime). `cpfe` must run with cwd at the
  base dir (`bases/docker/dev-env/gcc`) to find `lib/predefined_macros.txt`.
- **Generated C relies on C's UB**: signed `+` is emitted as plain `a + b`, pointers are typed
  (strict-aliasing applies), array indexing is unchecked. At `-O2` GCC folds `a + 1 < a` to false.
  Path A therefore needs `-fwrapv -fno-strict-aliasing`; real UB freedom needs Path B checks.
  `tests/cases/signed_overflow_wraps.cpp` guards this.
- Templates come out as `extern` declarations in the first pass; the prelinker re-invokes the front
  end to instantiate them, so Path A must keep going through `eccp`/`edg_prelink` (multi-TU safe).
- Vtables are emitted as `const long *__vptr` plus dispatch through function-pointer casts; lambdas
  become plain structs (`_ZZ4mainEUliE_`). Names are Itanium-mangled.

## Still open

- Runtime needs of generated C for exceptions/RTTI, and porting to Hexagon.
- How cleanly libc++/libstdc++ headers parse under `--g++`/`--clang` emulation.
- EDG IL documentation quality for the Path B lowering (see `doc/source/ext_intf.rst` in the EDG repo).
- QBE shift semantics; Hexagon SDK clang vs upstream LLVM compatibility.

## Next steps

1. Try `cproc` + QBE as the host back end instead of gcc (Path A, no-GCC variant).
2. Hexagon: feed generated C to the SDK clang; test with `hexagon-sim`.
3. Dump EDG IL, design the mid-level IR (structured CF, address spaces, explicit checks).
4. Path B subset -> QBE with translation validation.
5. Freestanding core library + shared builtins; SPIR-V/WGSL back end; HVX vectorization.
