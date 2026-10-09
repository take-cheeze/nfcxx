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
- **Sources**: `3rd/qbe` is [take-cheeze/qbe](https://github.com/take-cheeze/qbe), a daily mirror of upstream
  `https://c9x.me/git/qbe.git` (its `master` and tags; sync workflow + `scripts/sync-c9x.sh` live on that repo's `main`).
  Plain `git clone` of c9x.me fails (dumb-HTTP server resets connections), hence the curl-based sync script.
  `3rd/cproc` is michaelforney/cproc (needs a QBE new enough to parse `call extern`, i.e. current upstream).
  Move both forward together.
- **EDG output quirk**: EDG emits a top-level `__asm__(".align 2");` after functions; cproc has no top-level asm, so the
  wrapper strips it (alignment hint only).
- **Exceptions work** on the QBE backend (`tests/cases/exceptions.cpp`): EDG lowers them to plain C plus its EH runtime
  in `libC.a`, so cproc/QBE never see anything special.
- **Not supported by cproc** (so not by the QBE backend): `long double` ("long double is not yet supported"),
  `volatile` stores ("volatile store is not yet supported"), inline asm. All three work with `--backend=gcc`.
  `volatile` matters for MMIO on Hexagon/embedded targets; Path B must handle it itself.

## Path B plan: own back end on EDG's lowered IL

What EDG gives us (from `3rd/edg/doc/source/{lower_il,il,c_gen_be}.rst` and the sources):

- The front end builds a full **C++ IL**. An optional **IL lowering** pass (`lower_il.c`, `lower_init.c`, `lower_eh.c`,
  `lower_name.c`) rewrites it into a **C89-level, tree-structured IL**: templates already instantiated, classes laid out,
  constructors/destructors/new/delete expanded, exceptions turned into EH-runtime calls, vtables and name mangling
  (Itanium) chosen. This is exactly what `c_gen_be.c` prints as C; the generated C is "cfront-like, unreadable".
- The IL stays a **tree**: ~35 statement kinds (`stmk_block/if/while/for/switch/goto/label/return/try_block/init/...`)
  and expression nodes, walked with `il_walk.h`. Structured statements survive, which GPU targets (SPIR-V merge
  blocks, no goto in WGSL) need. `stmk_goto`/`stmk_label`/`stmk_assigned_goto` also exist, so a structurizer is still needed.
- **Plug point**: the front end calls `back_end()` (`cfe.c`) when `BACK_END_SHOULD_BE_CALLED`. `c_gen_be.c` defines it
  under `BACK_END_IS_C_GEN_BE`, and is ~12k lines that double as the reference IL traversal. Our back end is a new
  file that defines `back_end()` (plus a cleanup hook) and is linked into `cpfe` instead of `c_gen_be.c`.
- The IL is in memory when `back_end()` runs; the `--ii_file` IL-to-file path is compiled out in the stock config, so
  Path B means building `cpfe` ourselves (a CMake wrapper compiling EDG's sources with our back end and macro config)
  rather than driving the stock binary.
- Lowering can be skipped to see the C++ IL (classes, ownership-relevant types) before it is flattened; useful for
  language-level safety checks (borrowing) that C-level IL can no longer express.

Stages:

1. **Harness**: out-of-tree build of `cpfe` with `BACK_END_IS_C_GEN_BE` off and a stub `nfcxx_be.c`; dump the lowered
   IL of the existing `tests/cases` programs as an s-expression text form (this also becomes the Lean-side input format).
2. **Mid-level IR** (own, small): structured control flow, explicit address spaces, no UB-carrying ops. Every
   arithmetic/memory op that can be UB in C becomes an op with defined semantics or an explicit check that traps
   (div by zero, `INT_MIN / -1`, shifts >= width, array bounds, null).
3. **QBE emission straight from the IR** (drops the cproc hop and its gaps: `long double`, `volatile`).
4. **Translation validation** of IR -> QBE IL; formalize the IR + QBE subset in Lean.
5. GPU (SPIR-V/WGSL) and Hexagon (C + HVX intrinsics) back ends from the same IR.

## Still open

- Runtime needs of generated C for exceptions/RTTI, and porting to Hexagon.
- How cleanly libc++/libstdc++ headers parse under `--g++`/`--clang` emulation.
- EDG IL documentation quality for the Path B lowering (see `doc/source/ext_intf.rst` in the EDG repo).
- QBE shift semantics; Hexagon SDK clang vs upstream LLVM compatibility.

## Next steps

1. Replace the gcc assembler/linker with QBE-only tooling where possible (QBE emits asm; `cc` still assembles and links).
2. Hexagon: feed generated C to the SDK clang; test with `hexagon-sim`.
3. Path B stage 1 (see above): harness build of `cpfe` with our own `back_end()`, IL dump.
4. Path B subset -> QBE with translation validation.
5. Freestanding core library + shared builtins; SPIR-V/WGSL back end; HVX vectorization.
