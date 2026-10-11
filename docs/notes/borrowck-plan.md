# Borrow checker for the Path B IR: design plan

Status: plan only, no code. Written against `origin/main` at `265991b`. Every claim about the code cites a file
and a line, or a probe in the appendix. Probes were run through a harness built from this tree (appendix A).

## 0. Summary

- **Target: C++ code under an explicit opt-in mode.** The checker enforces Rust-style reference rules (exclusive
  mutable access, no use after a referent's scope ends, initialization, moves) on a checked subset of C++. It does not
  check C++ in general, and C++ code is not checked by Rust rules outside that subset. Section 3 gives the reasons.
- **Where it runs:** after lowering, on the IR. The lowered IL already has an explicit CFG, explicit constructor and
  destructor calls, and no `?:`, `&&` or `||` (section 1). Nothing needs the unlowered C++ IL for tiers A to C.
- **What must change:** the IR does not print four facts the checker needs: which pointers are references, where a
  local is declared, source positions, and which calls move an object. All four are present in memory during
  lowering, so the printer can add them behind an opt-in flag (tier 0). Section 1.2 has the evidence.
- **Tiers:** (A) initialization and use-after-move, dataflow on the CFG, about 1.2k LOC and 3-4 weeks. (B) overlapping
  borrows with liveness, NLL-like without lifetime parameters, about 1.8k LOC and 5-7 weeks. (C) region inference
  across signatures, about 2.5k LOC and 8-12 weeks, which for C++ needs annotations on the signatures.
- **Two corrections to the premise and the notes.** mrustc does have a borrow checker file, but it is a skeleton
  (section 4.4). And `docs/notes/pathb-stage1.md` and `pathb-stage2.md` say borrowing needs the unlowered C++ IL.
  That is true for some C++ rules (for example, overload resolution through a reference-returning operator). It is
  not needed for the three tiers planned here, because the reference flag and the declaration scopes survive lowering.

## 1. Where the checker runs

### 1.1 Options

| Option | Input | Pros | Cons |
| --- | --- | --- | --- |
| A. Before lowering | unlowered C++ IL | Sees `T&`, `T&&`, `enk_ref_indirect`, implicit conversions and object lifetimes as written | Needs the patched EDG option path (`suppress_back_end` is set by `-N`, `pathb-stage1.md`, "Surprises and things that do not work"). Has to rebuild the CFG and the destructor and temporary points itself |
| B. In the lowering pass | lowered IL, read while `nfcxx_ir.c` prints | No new EDG patch. Facts are read where they are already known | The checker lives in C inside `cpfe`. A bug in the checker is a bug in the compiler build. Slow to iterate |
| C. On the IR text | the printed IR (`ir-module` ... `function` forms) | The IR text is the interface Lean and the QBE emitter already read. The emitter has a tokenizer and parser (`scripts/pathb-qbe-emit.rb`, `tokenize`, `parse_forms`). The checker can be goldened and run without rebuilding EDG | Anything the checker needs must be printed. The text is the only input |

**Decision: C for tiers A and B, with the facts printed by the lowering (B's printer side, tier 0).** The checker is a
mruby script, `scripts/pathb-borrowck.rb`, run like the emitter through `scripts/mrb`. Tier C may move the summary
computation into the lowering if summaries need EDG's routine types in more detail than the text carries. Option A is
kept as a fallback only if a rule cannot be expressed on lowered code.

Reasons for the lowered form, not the unlowered one:

- Lowering already rewrites the constructs a CFG builder would otherwise have to handle. `?:`, `&&`, `||` and the comma
  become `if` (`docs/notes/pathb-stage2.md` section 4 (d)). `continue` becomes `(continue)`. Constructors are calls
  (`pathb-stage2.md` section 9 item 3). Destructors are explicit calls at each exit (probe `owner.cpp`, section A.2).
- The evaluation order is the one the lowering chose (`pathb-stage2.md` section 4). That is the order the checker
  must reason about, because C++ leaves most of it unspecified.

### 1.2 What the IR keeps and what it drops

Each row was checked against the source. A row marked "probe" was also checked at run time (appendix A).

| Fact the checker needs | In memory during lowering | In the printed IR | Evidence |
| --- | --- | --- | --- |
| Variable identity | Yes: `ir_slots` is keyed by `a_variable_ptr` (`be/nfcxx_ir.c:907-919`) | Partly: slot names are unique per function (`x`, `x.1`) (`ir_tab_add`, `nfcxx_ir.c:411-427`). Compiler temporaries are `tmp`, `tmp.N` in the same namespace | probe `refs.cpp` |
| Reference vs pointer | Yes: `variable->type->variant.pointer.is_reference` is 1 for `rx`, `r`, `ri`, `sr`, and 0 for `px`, `p` | **No.** `nf_put_unqualified_type` prints `tk_pointer` as `(ptr T)` (`be/nfcxx_be.c:133-135`) | probe `refs.cpp` (A.1). `lower_il.c` never reads or writes `is_reference` (grep) |
| Reference return type | Yes: `pick` returns a type with `is_reference=1` | No: `(ret (ptr int))` | probe `ret.cpp` (A.3) |
| Mangled parameter kinds | Yes, as the Itanium name | Yes, in the function name (`_Z4pickRiS_`: `Ri` is `int&`, `S_` a substitution) | probe `ret.cpp` |
| Rvalue references | `is_rvalue_reference` (`il_def.h` ~10203) | No | Not yet probed on a variable, and not checked at call sites |
| Declaration point | `stmk_decl` has `entities` (`il_def.h` 16794-16808) | **No.** `stmk_decl` prints nothing: "Storage is per function" (`nfcxx_ir.c:5248-5250`) | source |
| Block scope membership | `a_scope.nonstatic_variables` (`il_def.h` 18483), `a_block.assoc_scope` (`il_def.h` ~15869) | Only `(block ...)` nesting. Scalar locals have no end marker | source, probe `refs.cpp` (`inner`, `ri`) |
| End of scope for class locals | Yes | Yes: explicit `(eval (call void &"_ZN3OwnD1Ev" $"b"))` before each exit, including early `return` | probe `owner.cpp` (A.2) |
| Temporary lifetime | `enk_object_lifetime`, `olk_expr_temporary` (`il_def.h` 13592, 17636) | Unwrapped and dropped (`nfcxx_ir.c:1361-1363`). Temporaries are slots with no end | source |
| Address taken | `a_variable.address_taken` (`il_def.h` 11382) | No. Shows only as `$"x"` operands | source |
| Source position | Every `a_statement` has `position` (`il_def.h` 16518; `basics.h` 897) | No. Zero uses in `nfcxx_ir.c` | `grep` |
| Move | No move node. A move is a constructor with an rvalue-reference argument | Only as the call `(eval (call void &"_ZN3OwnC1EOS_" $"tmp.2" $"b"))` (probe `owner.cpp`) | probe `owner.cpp` |
| Exception unwinding | Destructors run from runtime region tables (`pathb-stage3.md`, "C++ exceptions") | No edges. The tables store the addresses of the live objects: `(store (ptr void) %13 %11)` with `%11 = $"a"` in probe `owner.cpp` | probe `owner.cpp`, `pathb-stage3.md` |
| Control flow | Yes | Yes: `if`, `loop` with `step`, `switch`, `goto`, `label`, `break`, `continue`, `return` (`pathb-stage2.md` section 2) | goldens |
| Gaps | n/a | `(unsupported ...)` markers from 46 call sites of `ir_gap` (`nfcxx_ir.c`). Goldens with markers: `asm_refuse.ir` (3), `gaps.ir` (1) | `grep` |
| Which unit a function belongs to | `source_corresp` and the position's sequence number, mapped to a file by EDG | No flag. Every function is printed | source |

Two consequences matter for the design:

1. **Reference-ness is lost in text but not in memory.** The printer can add it cheaply. The alternative, rebuilding it
   in the checker from the mangled name, works for `R` and `O` parameters but not for returns, members, or variables,
   so it is a fallback only.
2. **Exception unwinding is invisible.** A destructor that runs during an exception reads objects at points where the
   IR shows no call. Tier A and B must model that conservatively (section 2, open questions).

### 1.3 Tier 0: what the printer adds

All additions go behind `NFCXX_PATHB_BORROW=1`, so the 62 goldens in `tests/pathb-ir` and the QBE probes do not change
by default. The additions are new statements, which the emitter must accept as no-ops. The emitter currently refuses any
unknown statement head (`scripts/pathb-qbe-emit.rb:1051-1052`, `Refused`) and any unknown top-level form (`:2845-2846`).
So the emitter's `STMT` table and its top-level check, and the Python oracle
`tests/mruby/oracle/pathb-qbe-emit.py`, both need the new forms. The run in `tests/mruby/run.sh` compares the two.

Proposed forms (exact spelling is a tier 0 decision):

```
(decl $"rx" ref)            at the declaration point (from stmk_decl.entities); ref | val | temp | param
(decl %0 ref)               a reference parameter (ref, from the parameter's a_variable)
(scope-end $"inner")        at the end of the scope that declares it (block end, break, return path)
(rref-arg $"b")             immediately before a call whose parameter is an rvalue reference to $"b"
(at SEQ COL)                source position on each statement (only with the flag)
(checked)                   on a function marked for checking (opt-in attribute, section 3)
```

`(scope-end)` is needed only for tier B's "does not live long enough" rule. Class locals already have destructor calls
at their ends, so tier A can use those. The `(at)` form is needed for diagnostics only.

## 2. The three tiers

Each tier is decided on the CFG built from the IR. Loops, `break`, `continue`, `goto`, `switch` and `return` become
edges. Facts are per function. The checker works only in functions marked `(checked)`, and refuses to certify a
function that contains an `(unsupported ...)` marker. Refusal is a diagnostic, not a silent pass.

### 2.1 Tier A: initialization and use after move (dataflow on the CFG)

**Data.** One basic block per straight-line run of statements, with edges from the structured forms. Per function, one
bit per local slot and one bit per (slot, field offset) for aggregates written by direct field stores. Events on a
slot: `init` (a store to it, a constructor call whose first argument is its address, or a `bfstore`), `use` (a load, or
a pointer to it passed to a call), `move` (a `(rref-arg)`), `drop` (the destructor call at a scope exit), and `decl`.

**Algorithm.** Forward "maybe uninitialized" and "maybe moved" analyses, meet by union, worklist to a fixed point, over
the event sequence of each block. A read of a slot that is maybe-uninitialized on some path is an error, and so is a
use of a maybe-moved slot, for a type marked as moved-from-is-dead (section 3). Field granularity applies only to
direct member stores (`(offset $"s" N)`). An address that escapes (stored to memory, or passed to a function that
takes a raw pointer) makes the slot "initialized by unknown code" from then on, so the analysis does not report it.

**Proves.** A read of a local that no path initializes is an error. A read of a local that some path leaves
uninitialized is an error, which is stricter than C++ (C++ only says the read is undefined). A use of a moved-from
object is an error for opted-in types.

**Cannot prove.** Anything about pointers or references (tier B). Initialization through an escaped address. Reads of
members through a pointer. Anything on an exception path (section 5). The result is only as good as the moved-from
annotation: for ordinary C++ types a move leaves the source valid and unspecified, so nothing is reported.

**Size.** CFG builder 350 LOC, event extraction 300, the two dataflow passes 250, diagnostics 150, tests 150.
About **1.2k LOC, 3-4 weeks**, including tier 0 for `decl` and `rref-arg`.

### 2.2 Tier B: overlapping borrows with liveness (NLL-like, no lifetime parameters)

**Data.** A loan is a triple (place, kind, creation point) where a place is a slot plus a projection (field offset, or
"whole array" for an indexed access). Kind is shared or mutable. A reference local's **liveness** is a backward dataflow
over the CFG (live at a point if a later use happens before its next assignment). A loan is live at a point if some
live reference local was created from it, directly or through a chain of copies. This is the NLL rule without
lifetime parameters: a region is the set of points where a reference is live.

**Creation.** A loan is created where the IR takes an address of a place and stores it into a reference-flagged slot:
`(store (ptr int) $"rx" $"x")` with `rx` marked `ref` (tier 0) creates a loan on `x`. A reference argument of a call
creates a loan that is live for the call only, unless the call returns a reference (tier C).

**Conflicts.** At each access to a place P (a read, a write, or a call that may touch it), any live loan that overlaps P
and conflicts with the access (a write conflicts with every live loan; a read conflicts with a live mutable loan) is
an error. Calls access every global and every escaped place, so a mutable loan on a global is reported across a call.
That is conservative and matches Rust's behaviour for `&mut` across calls.

**Escapes.** A place is escaped if its address goes anywhere other than a reference slot or a direct call argument of
a reference parameter. A `*p` access through a raw pointer to an escaped place is unchecked. The checker reports the
escape as a diagnostic in checked functions (strict). It does not stay silent (section 3).

**Proves.** Within a checked function, no two live loans on overlapping non-escaped places conflict. A reference local
is not used after its referent's scope has ended, when the reference is live across the scope end (`(scope-end)`).

**Cannot prove.** Anything across function boundaries (tier C). Aliasing through raw pointers, globals reached by
other code during a call that the checker cannot see into, members reached through `this` in other functions, threads,
inline asm, and anything on an exception path. Two-phase borrows (`v.push_back(v.size())`) need a rule. The first version
treats a call's arguments as created in order, so `f(x, x = 2)` is decided by the lowering's order, not by C++.

**Size.** Loan and liveness dataflow 600 LOC, conflict and escape checks 300, the scope-end rule 150, tests 200. About
**1.8k LOC, 5-7 weeks**.

### 2.3 Tier C: lifetimes across signatures (region inference)

**Data.** A region variable for each reference-typed value (a parameter, a return, a call result, a reference local).
Outlives constraints from assignments and calls. A **per-function summary**: for each reference return, the set of
parameters it may borrow from. Summaries are keyed by the Itanium mangled name, which is stable across translation
units (`_Z4pickRiS_`). For a template instance or an `extern "C"` function the key is the symbol the IR already prints.

**Elision (C++ form).** If a function has exactly one reference parameter (or a `this` parameter, which is a reference),
its reference return borrows from it. With several reference parameters and a reference return, the function needs an
annotation that names the source parameter, the same as Rust's rule. The annotation is a design decision (open question
5.4). Clang's `[[clang::lifetimebound]]` is an existing precedent for that kind of annotation.

**Algorithm.** Solve the region constraints per function as sets of loans and points (the NLL style of tier B),
propagating loans from arguments to results through the summary. At a call, the loans of the arguments flow into the
result's region. A result that is live past the referent's scope is an error, and so is a reference return to a local.

**Proves.** A reference returned from a call borrows only from the arguments the signature (or the annotation) names.
A reference returned from a function is not a reference to a local of that function.

**Cannot prove.** Any reference stored in an object: a struct or class with a reference member, a lambda that captures
by reference, a `std::reference_wrapper`. Those need a region parameter on the type, which is a language decision (C++
has no lifetime parameters). The same holds for `std::string_view`, `std::span` and iterators: they are not references
in the type system, so this checker does not see their borrows at all.

**Size.** Region solver 800 LOC, summaries and their cross-unit file format 400, the elision and annotation rules 300,
diagnostics 300, tests 400. About **2.5k LOC, 8-12 weeks**, and it depends on the annotation design.

### 2.4 Summary of estimates

| Tier | What it proves | LOC | Weeks (one engineer, after a ramp-up week) |
| --- | --- | --- | --- |
| 0 (printer and emitter support) | nothing by itself | 200-300 (printer), 60 (emitter and oracle) | 1-2 |
| A | initialization; moves of opted-in types | about 1.2k | 3-4 |
| B | exclusive access inside a function; scope ends for live references | about 1.8k | 5-7 |
| C | returned references, across signatures, with annotations | about 2.5k | 8-12 |

The estimates assume that the EDG facts in section 1.2 are all reachable from the printer, and that the mruby
checker runs fast enough on the checked functions. Both are unverified; section 5 lists them.

## 3. Target language: C++ under an opt-in mode, and why not Rust

**The checker is for C++, restricted to an opt-in subset, with Rust-style reference rules applied to that subset.**
It is not a Rust borrow checker, and it does not check C++ in general.

Why not Rust:

- No Rust front end exists in this repository. nfcxx's only front end is EDG C++. A Rust checker would need a
  Rust front end first, which is a different project.
- mrustc's MIR is the input of its own checker (section 4.4). Porting that design would mean porting mrustc's HIR and
  type checker too, and mrustc's checker is not finished.
- The IR's semantics are C++ semantics. A Rust-only rule (for example, "a reference is exclusive") would be false for
  any C++ code the checker did not see.

Why C++ under opt-in, and what it means:

- In C++ references are not exclusive by default. `int &a = x, &b = x; a = 1; b = 2;` is valid C++. In a checked
  function it is rejected, because `a` and `b` are both live and both mutable. That is a rule of the checked subset, not
  of C++.
- In C++ a raw pointer may alias anything. `int *p = &x; x = 1; *p = 2;` is valid C++. In a checked function,
  taking a raw pointer to a borrowed place is a diagnostic (section 2.2, escapes), because the checker cannot see
  where the pointer goes.
- A C++ move does not leave the source dead. `Own b2(static_cast<Own&&>(b)); use(b);` is valid C++, and nothing is
  reported unless the type is opted in as moved-from-is-dead (section 2.1).
- Opt-in is by a function attribute, for example `[[nfcxx::checked]]`, or by a file-level pragma. A checked function
  may call unchecked functions. The calls are treated as in section 2.2 (they may touch globals and escaped places).
- Anything outside the opt-in subset is not checked. The checker says nothing about it, and no claim in this plan
  applies to it.

## 4. Test strategy

### 4.1 Golden IR tests (`tests/pathb-ir`)

- The annotations go into new goldens under `tests/pathb-ir/borrow/`, produced with `NFCXX_PATHB_BORROW=1` by a
  `--borrow` mode of `tests/pathb-ir/run.sh`. The 62 existing goldens are not regenerated, because the flag is off.
- The checker's own output (diagnostic lines, or `ok`) is goldened too, so a change in the CFG shows up as a diff.
- Every golden is printed by the harness built from the same tree (section 5.6). A stale harness produces a valid
  but different golden (appendix A.4).

### 4.2 Error-case tests (`tests/mruby/pathb-edge`)

- Hand-written files `bck_*.ir` in `tests/mruby/pathb-edge/`, one per rule: a use of an uninitialized local, a moved-from
  use, a shared and a mutable loan that overlap, a reference that outlives its referent, a reference return to a
  local, an escaped place, and the "must accept" twin of each (a borrow that ends at its last use).
- Each file is valid IR with the tier 0 annotations, so the emitter and its oracle accept it as far as the
  emitter's own rules go (they must skip the annotations). The expected diagnostic goes in a sidecar file,
  `bck_NAME.expect`, one line per diagnostic. The `tests/mruby/run.sh` comparison of emitter and oracle over
  `pathb-edge` keeps working unchanged.
- A new runner, `tests/pathb-borrow/run.sh`, runs the checker over the `bck_*.ir` files and compares its output with
  the sidecar files.

### 4.3 Positive programs and false positives

- **Positive C++ programs** in `tests/borrowck/*.cpp`, each marked `[[nfcxx::checked]]` and carrying a
  `// EXPECT: ok` or `// EXPECT: error CODE` line. Each one must also be valid C++ that gcc accepts, so the test
  shows the checked subset is a subset of C++ and not a different language. Accepted programs must also pass
  translation validation (`tests/pathb-qbe/run.sh`), so the checker cannot accept a program that the QBE path miscompiles.
- **False positives on the existing corpus.** No existing test is opted in, so the checker reports nothing on
  `tests/cases` (22 programs; 14 without the `qbe_` prefix), `tests/pathb-qbe/cases` (100 probes), `tests/pathb-qbe/traps`
  (24) and `tests/pathb-qbe/multi`. That holds by construction, and a test asserts it.
- A **shadow mode** (`--report-all`) forces checking on every function of those programs and records the diagnostics
  in a file under `tests/pathb-borrow/shadow/`. The count of diagnostics is a ceiling that may only go down. Each
  diagnostic in the shadow file is labelled as a true or false positive by hand, with a reason. This measures how far
  the checked subset is from real C++, which matters for the design of the opt-in.

### 4.4 Reference points in mrustc

mrustc has a borrow checker file, `mrustc/src/mir/borrow_check.cpp` (801 lines). It is opt-in with `-Zborrowcheck`
(`mrustc/src/main.cpp:1136`; `params.run_borrowcheck` at `:702`). The per-function driver (`MIR_BorrowCheck`, `:491`)
allocates region variables for each borrow type (`allocate_ivar`, `:464`, `:519`) and walks assignments, borrows and
calls to unify the types. The state check that would report a failure is commented out (`:68-69`), and the body ends
with `// TODO: Figure out the rest` (`:789-790`). I found no path that reports a borrow error. Its locals are typed but
unnamed (`mir.hpp:749-750`). Its calls carry an explicit unwind target (`Call.panic_block`, `mir.hpp` ~638), which the
IR does not have. Its MIR is the reference for a field-sensitive place model, and not much more than that for now.

## 5. Risks and open questions

1. **Golden churn.** A printer change that is not flag-gated rewrites the 62 goldens in `tests/pathb-ir`, 40 of them
   from probes in `tests/pathb-qbe/cases`. The flag exists to prevent that; a test must check that the default output
   is unchanged.
2. **Emitter and oracle must learn every new form.** Both refuse unknown forms (section 1.3). A form added to the
   printer but not to both emitters breaks `tests/mruby/run.sh` and `tests/pathb-qbe/run.sh` for every checked program.
3. **Exception edges.** Unwinding is invisible in the IR (section 1.2). Options: (a) treat every call as an edge to
   the cleanup of every live object (sound, noisy); (b) take the facts from EDG's region tables. `setjmp` returns
   twice: the state at the catch entry must be the union of the states inside the try. Not decided.
4. **Annotation design for tier C.** Elision covers one reference parameter. For several, the annotation's form and
   spelling are open. So are the rules for references in members and lambdas (section 2.3), which need a region
   parameter on the type.
5. **Evaluation order.** The checker's semantics follow the lowering's order (`pathb-stage2.md` section 4), not C++'s,
   where the order is unspecified. Two-phase borrows depend on it. A test must fix the order the checker assumes.
6. **Harness provenance.** A prebuilt harness can be older than the source it is meant to test. `build/pathb` in
   `/home/user/nfcxx` was built on 2026-10-09 and is older than `be/nfcxx_ir.c` (2026-10-10). It printed
   `(unsupported lvalue lvalue_adjust)` for an expression the current source lowers. Every golden in this plan must be
   built from the same tree as the checker. `scripts/setup-pathb.sh` takes `PATHB_EDG_SRC` and `PATHB_OUT`, so a
   scratch build is cheap (about three minutes, `ninja cpfe`).
7. **Performance.** mruby is fast enough for the probes. Hosted-header programs can produce large IR. The checker must
   run on the functions of the translation unit only, which needs a flag the printer does not have (section 1.2, last
   row). If the mruby run is too slow on hosted programs, the checker moves to C in the lowering (option B).
8. **Diagnostics.** Positions are sequence numbers and columns (`basics.h:897`). Mapping them to file and line goes
   through EDG's file table. Not yet checked.
9. **Reference members, lambdas and views.** Tier C does not see borrows stored in objects, or the borrows of
   `std::string_view`, `std::span` and iterators (section 2.3). A user of the checked subset must know that. The
   checked subset should refuse those types in a checked function, instead of ignoring them.
10. **Scope of the claim.** Every claim here is about the checked subset, under the assumptions of section 2, not about
    nfcxx's C++ as a whole. The docs and the diagnostics should say so.

## Appendix A: evidence and reproduction

### A.1 References and pointers (`refs.cpp`, probe)

```cpp
static void take_mut(int &r) { r = 3; }
static int take_ro(const int &r) { return r; }
int test(bool c) {
  int x = 1;
  int &rx = x;          // reference to a named local
  int *px = &x;         // plain pointer to the same local
  take_mut(rx);
  int y = take_ro(5);   // const reference bound to a temporary
  { int inner = 2; int &ri = inner; y += ri; }
  ...
}
```

Printed IR, fresh harness:

```
(store (ptr int) $"rx" $"x")
(store (ptr int) $"px" $"x")          ; identical text
(store int $"tmp" (const int 5))      ; the temporary for take_ro(5)
(let %2 int (call int &"..take_ro..." $"tmp"))
```

Run-time flags of the same variables (scratch-only debug print in the harness, not in the repository):
`rx`, `r`, `ri`, `sr`: `is_reference=1`. `px`, `p`: `is_reference=0`.

### A.2 Destructors, moves and early return (`owner.cpp`, probe)

```cpp
struct Own { int *p; Own(int v); Own(Own &&o); ~Own(); };
void consume(Own o);
int f(bool early) {
  Own a(1);
  { Own b(2); consume(static_cast<Own&&>(b)); }
  if (early) return 0;
  int *q = a.p;
  return *q;
}
```

Relevant IR: the move is `(eval (call void &"_ZN3OwnC1EOS_" $"tmp.2" $"b"))`. The end of the inner block is
`(eval (call void &"_ZN3OwnD1Ev" $"b"))`. The early return calls `_ZN3OwnD1Ev` on `$"a"` before `(return (const int 0))`.
The EH table is filled with `$"a"` and `$"b"` addresses. No `_setjmp` appears, because no try block is present.

### A.3 Reference return (`ret.cpp`, probe)

`int &pick(int &a, int &b)` prints as `(function "_Z4pickRiS_" (ret (ptr int)) (params (param %0 "a" (ptr int)) ...))`.
Its return type has `is_reference=1` in memory.

### A.4 Stale harness

The prebuilt `/home/user/nfcxx/build/pathb/cmake/bin/cpfe` (2026-10-09) printed
`(unsupported lvalue lvalue_adjust)` for `take_ro(5)`. The fresh build from this tree printed the correct store. The
prebuilt binary is older than `be/nfcxx_ir.c` and cannot be used to check this plan.

### A.5 Reproduce

```
PATHB_OUT=<scratch>/pathb PATHB_EDG_SRC=/home/user/nfcxx/3rd/edg scripts/setup-pathb.sh
PATHB_CPFE=<scratch>/pathb/cmake/bin/cpfe PATHB_BASE=<scratch>/pathb/edg-base scripts/pathb-dump --ir refs.cpp
```

The probes are not committed. They live in the session scratchpad.
