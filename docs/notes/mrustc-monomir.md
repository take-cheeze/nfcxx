# mrustc's monomorphised MIR as a Rust frontend (design)

Status: **native QBE route implemented.** `scripts/mrustc-monomir.sh` lowers mrustc's
`-C codegen-type=monomir` output through `scripts/monomir-to-pathb.rb`, Path B IR and QBE.
The program and its reachable generic functions use this route; the remaining crate functions
link against mrustc's gcc-built objects. The C route (`scripts/mrustc-nfcc.sh`, see
`mrustc-frontend.md`) remains available.

Run `tests/mrustc/run-monomir.sh` for the runtime suite, including integer match regressions
(`SWITCHVALUE`, signed values and 64-bit constants). Run real crates with
`tests/realworld/run_mrustc.sh --monomir [case...]`; the driver reads the dump's `crate` records
to find dependency objects, including crates supplied through `--extern`. The regex and batch cases pass.
Serde JSON currently prints the first three expected lines and then aborts during serialization:
its `State::eq` receives an invalid state byte. Integer match lowering is covered, but this
remaining state-byte corruption is unresolved. Clap still fails to link because type-ID
symbols such as `String::type_id` are missing.

The same translator with `--borrow` writes input for nfcxx's borrow checker instead of code
(`scripts/mrustc-borrowck.sh`, see `mrustc-borrowck.md`).

The design below describes the original plan; CIL and unwinding remain future work.

## 1. What mrustc emits (probe, `tests/mrustc/hello.rs`)

`mrustc hello.rs -o hello -L build/mrustc/src/output-1.90.0 --edition 2021 -C codegen-type=monomir` writes `hello.mir`
(243 lines for hello, 10 KB) and an empty `hello`. The file is a text dump of the monomorphised program:

- `crate "...rlib.mir";` lines: one per crate, the `.mir` files that mrustc's standard library build also wrote.
- `type NAME { SIZE n, ALIGN n; off = ty; ... }`: a type with its layout. Offsets are on the fields, and enum
  variants are fields at their offsets with a tag encoding (`@[1, 0] = { "\0...", * =1 }`). This is the layout
  information the translator needs; it is not recomputed from the Rust type.
- `static NAME: TYPE = <encoded literal>`: statics with their initial bytes, including relocations (`{@0+8 = "Hello, world!\n",}`).
- `fn NAME(args): RET { let varN: TY; ... N: { STATEMENTS; TERMINATOR } ... }`: one body per reachable
  monomorphised function. Basic blocks are numbered; terminators are `goto N else M`, `RETURN`, `DIVERGE`, and calls
  with a normal and an unwind target. Statements are `ASSIGN place = rvalue`, with rvalues such as `MAKEDST ADDROF`,
  `ENUM T variant { ... }`, and aggregate literals `{ a, b, c, }: T`.

Only the reachable set is emitted: hello's `main` pulls in `lang_start`, `__print`, the `fmt` runtime and the
closure vtables, and nothing else. Size is not a problem at this scale.

## 2. Why Path B IR as the target

- Path B IR already exists, is nfcxx's own IR, and has two back ends that are tested: the CIL back end
  (`docs/notes/pathb-cil.md`) and the QBE back end (`pathb-qbe`). Lowering MIR to Path B IR reuses both.
- The C route goes through C text, cproc and QBE. A monomir → Path B IR translator skips the C text and cproc
  and gives the same QBE and CIL outputs the C++ front end gets.
- The alternative, a new QBE emitter straight from MIR, would duplicate what Path B's back ends already do.

## 3. Pipeline

```
prog.rs --mrustc -C codegen-type=monomir--> prog.mir (types, statics, fn bodies)
prog.mir --monomir-to-pathb--> prog.pathb IR
prog.pathb --pathb-qbe--> QBE --> as --> object
prog.pathb --pathb-cil--> CIL (later)
```

The translator is a new tool, not a change to mrustc. Its input is the text in section 1; its output is Path B IR.
The C backend is the reference for what each construct has to lower to: `src/trans/codegen_c.cpp` in mrustc is 8,600
lines, and `codegen_mmir.cpp` (the emitter of the text above) is 1,176. The translator needs the lowering the C
backend does, not its text output.

## 4. What the translator must cover

- **Layouts and types:** from the `type` records, not recomputed. Enum tags, niche values (`@[1, 0] = { ... }`) and
  zero-sized types are all in the dump.
- **Statements:** `ASSIGN`, aggregate construction, `ENUM` construction, `ADDROF`/`MAKEDST` (fat pointers),
  casts, binary and unary operators with mrustc's overflow semantics.
- **Terminators:** `goto`, `RETURN`, `DIVERGE`, and calls with unwind edges. The unwind edges are where Path B's
  exception handling (see `pathb-cil.md`) and QBE's lack of unwinding must be settled first; `panic = abort` is the
  first target, which matches what mrustc's own build does.
- **Intrinsics:** mrustc's C backend implements them in C (`codegen_c.cpp` has about 30 intrinsic sites, for example
  the 128-bit `ctlz` helpers). Each one the standard library reaches needs a Path B lowering. The list comes from
  the `CALL` targets in the dump, not from memory.
- **Statics and vtables:** encoded literals with relocations, and vtable statics (hello has three closure vtables).
- **Symbols:** the monomorphised names (`ZRG...`) are mangled by mrustc; the translator keeps them verbatim so the
  C route and this route link the same std.

## 5. Milestones

1. **M0, hello.rs:** the translator handles everything in hello's dump, Path B IR goes through `pathb-qbe`, the
   binary prints `Hello, world!`. Compared with the C route's binary and with rustc's output.
2. **M1, vec_sum and the threads case:** allocation, iterators, `format!`, atomics. These exercise most intrinsics.
3. **M2, the 15 `tests/mrustc` cases** through this route, and then `tests/realworld/run_mrustc.sh` with the
   translator in place of `mrustc-nfcc.sh`.

Each milestone is compared with the C route: same output, same exit code.

## 6. Open questions

- Unwinding: `DIVERGE` and unwind edges need a decision before anything with `panic = unwind` works.
- Which Path B back end runs the std code: QBE for the native binary, CIL for `.NET`, or both. Only QBE is in scope
  for M0.
- Whether the translator reads the `.rlib.mir` files of the other crates too (the std crates), or only the program's
  own dump. hello's dump includes the whole std reachable set, so the answer is probably "the program's dump only".
- Intrinsic coverage: unknown until the translator sees a larger program's dump.
