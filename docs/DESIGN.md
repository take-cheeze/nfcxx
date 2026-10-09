# nfcxx design

Experimental, lightweight C++ compiler. Goals: no LLVM build, host + Hexagon DSP + GPU targets,
UB-free by construction (with a path to Lean proofs), minimal API-compatible standard library.

## Pipeline

```
C++ --EDG front end--+--> Path A: EDG C back end -> C -> host cc            (implemented, host)
                     |                                 -> Hexagon SDK clang (planned)
                     +--> Path B: EDG IL -> own mid-level IR -> QBE / C+HVX / SPIR-V,WGSL (planned)
```

Path A is what `./nfcxx` does today: the generated C goes through `cproc` -> QBE IL -> `qbe` -> asm (default),
or through gcc with `--backend=gcc`. Path B is the long-term design: structured control flow,
explicit address spaces, explicit safety checks inserted when lowering from EDG's IL.

## Findings so far (answers to the handoff's open questions)

- **EDG builds with GCC 13** (~3 min on 4 cores), after dropping `-Wno-error=return-mismatch`
  (a GCC 14 flag) from `bases/docker/dev-env/gcc/edg_eccp_config`. `scripts/setup-edg.sh` does this on a copy of the base dir, keeping the `3rd/edg` submodule clean.
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

## QBE back end (Path A, host)

`scripts/qbe-cc` is a gcc-style compiler wrapper handed to `eccp` (via `NFCXX_CC`, which `setup-edg.sh` wires
into the copied `edg_eccp_config`): `cc -E | cproc-qbe | qbe | cc -c`; the link step still uses `cc`.

- **Signed overflow wraps without any flags**: cproc/QBE don't exploit C UB, so `tests/cases/signed_overflow_wraps.cpp`
  passes on the QBE backend without `-fwrapv`. Division by zero, `INT_MIN / -1` and float->int overflow are still
  machine-dependent in QBE and need checks inserted by us (Path B).
- **Pinning**: upstream QBE (c9x.me) is unreachable from the sandbox, so `3rd/qbe` is `michaelforney/qbe`
  (2021-10). `3rd/cproc` is pinned at `5d6c4cd`, the last commit before cproc emits `call extern` (unknown to that QBE).
  Newer cproc also emits `neg`, which the old QBE lacks; `qbe-cc` lowers it to `sub 0, x` (and `sub -0.0, x` for
  floats, which keeps the sign of zero). Older cproc (<= Feb 2022) can't parse `extern __attribute__(...)`, so there is
  no single cproc commit that avoids the rewrite. Move qbe and cproc forward together once upstream QBE is reachable.
- **EDG output quirk**: EDG emits a top-level `__asm__(".align 2");` after functions; cproc has no top-level asm, so the
  wrapper strips it (alignment hint only).
- **Not yet covered**: C++ exceptions (the EH runtime in `libC.a` is only linked, never exercised by tests), `volatile`
  and `long double` (cproc lacks them), inline asm.

## Still open

- Runtime needs of generated C for exceptions/RTTI, and porting to Hexagon.
- How cleanly libc++/libstdc++ headers parse under `--g++`/`--clang` emulation.
- EDG IL documentation quality for the Path B lowering (see `doc/source/ext_intf.rst` in the EDG repo).
- QBE shift semantics; Hexagon SDK clang vs upstream LLVM compatibility.

## Next steps

1. Replace the gcc assembler/linker with QBE-only tooling where possible; exercise exceptions and `long double` under QBE.
2. Hexagon: feed generated C to the SDK clang; test with `hexagon-sim`.
3. Dump EDG IL, design the mid-level IR (structured CF, address spaces, explicit checks).
4. Path B subset -> QBE with translation validation.
5. Freestanding core library + shared builtins; SPIR-V/WGSL back end; HVX vectorization.
