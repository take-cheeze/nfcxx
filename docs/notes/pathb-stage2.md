# Path B stage 2: the mid-level IR

Status: first implementation. `be/nfcxx_ir.c` lowers the lowered EDG IL of `tests/cases/*.cpp` to the IR below and
prints it, with no unsupported nodes on those programs. Goldens: `tests/pathb-ir/*.ir`, checked by
`tests/pathb-ir/run.sh`. Nothing consumes the IR yet: there is
no QBE, SPIR-V or WGSL emitter, no checker, and no execution. Sections 1-8 are the spec; section 9 says what is
implemented, what is not, and the coverage numbers.

## 0. Pipeline position

```
C++ -> EDG front end -> lowered file-scope IL (in memory)
        -> back_end()  [be/nfcxx_be.c]
             NFCXX_PATHB_MODE=il  (default): stage 1 IL dump, s-expressions     (docs/notes/pathb-stage1.md)
             NFCXX_PATHB_MODE=ir             : stage 2 IR, s-expressions         (this document)
```

Both modes are one `cpfe` built by `scripts/setup-pathb.sh`. `scripts/pathb-dump --ir file.cpp` selects the IR mode.

## 1. Decision (a): the IR is built inside the back end, from the lowered IL

The IR is produced by `back_end()` from the lowered IL that is in memory, as stage 1 does. Consequences:

- The IR sees exactly what EDG's C generator sees after `DO_IL_LOWERING=1`: templates instantiated, constructors,
  destructors, `new`/`delete` expanded, exceptions turned into EH-runtime calls, vtables chosen. Nothing is re-parsed.
- There is no text round trip. The s-expression text is the IR's output format for goldens and for Lean; it is not
  read back by the compiler.
- The cost is that the IR is only available while `cpfe` runs. A separate step would need the IL serialized first.

**The unlowered C++ IL path is not used now.** Stage 1 found that `-N` (`no_il_lowering`) sets `suppress_back_end` in
this EDG (`optk_write_unlowered_il`), so `back_end()` is never called and no C++ IL reaches our code. Getting it means
patching EDG's option handling in a copy of the tree, or hooking `fe_wrapup` before lowering. Both are outside this
stage. The lowered IL keeps every construct the IR needs (structured statements, typed expressions, layouts through
`il_def.h` field offsets and `f_size_of_type`). The language-level checks that want the C++ IL (borrowing, for
example) are a later stage and need that hook first.

## 2. Decision (b): structured control flow, with goto as the fallback

Statements that the IR represents directly:

| Form | Meaning |
| --- | --- |
| `(block S...)` | sequence |
| `(if C (then S...) [(else S...)])` | two-way branch on a bool operand |
| `(loop (body S...) (step S...))` | repeat { body; L_cont: step }. `(break)` leaves the loop. There is no `(continue)` node yet: a source `continue` is a `goto` (see 9) |
| `(switch OP (body S...))` | C switch: `(case (const T V))` and `(default)` are markers inside the body; control falls through them. `(break)` leaves the switch |
| `(goto "L")`, `(label "L")` | unstructured jump, kept as the explicit fallback |
| `(return [OP])`, `(unreachable)` | return; `unreachable` is a trap (see 4) |

`while` is `(loop (body (if C (then) (else (break))) S...) (step))`. `do-while` puts the test in `step`, so `continue`
reaches it. `for` is `init; (loop (body (if C (then) (else (break))) S...) (step INC))`. `while`, `do` and `for` therefore
share one construct, and the structured form is what WGSL `loop { ... continuing { ... } }` and SPIR-V
`OpLoopMerge` need.

Limit: `switch` keeps C fallthrough between markers. WGSL has `fallthrough` but SPIR-V and WGSL both need the arms
split for a structurizer, so `switch` is structured only when each arm ends in `break` or `return`. `goto` is kept
rather than structurized here; the structurizer is a later pass that must remove every `goto` before WGSL emission.

## 3. Decision (c): typed three-address form

Expressions are flattened into `(let %N TYPE RVALUE)`. A register is declared once with its type. Registers are
**mutable, not SSA**: `(set %N OPERAND)` assigns a register declared earlier. This is the one place where mutability is
needed (the join of section 4). A later pass can convert to SSA with dominance frontiers; QBE and SPIR-V both want SSA
(QBE via its own phi/blocks, SPIR-V via `OpPhi` or memory variables).

Local variables and temporaries of aggregate type live in stack slots, `(slot "x" TYPE)`, one per function, referenced
as `$"x"`. Static objects are `@"x"`, functions `&"f"`. Every scalar local is a slot too, so each named variable has an
address; a later mem2reg pass removes the slots that are never address-taken. Parameters are copied into their slots
in the prologue.

Operands are `%N`, `(const T V)`, `(null PTR)`, `$"x"`, `@"x"`, `&"f"`. Each register and each constant has an IR type.
Loads and stores carry the type of the object: `(load T ADDR)`, `(store T ADDR VALUE)`.

Aggregates are never SSA values. A value of struct, class, union or array type is the address of an object that holds
it; assignment and argument passing are `(copy BYTES DST SRC)`. Parameters of aggregate type are `byval`: the caller
copies into a temporary and passes its address. An aggregate result is written through a hidden first parameter
`(sret %0 TYPE)`, and the function returns `void`.

## 4. Decisions (d) and (e): ?:, &&, ||, comma as control flow; checked and wrapping arithmetic

**(d)** The EDG operators `question`, `land`, `lor` and `comma` are never expressions in the IR:

- `c ? x : y` is `(let %r T zero)`, then `(if C (then ... (set %r X)) (else ... (set %r Y)))`. For void results there is no join.
- `a && b` is `(let %r bool false)`, `(if A (then B' (set %r B')))`, where `B'` is `b` converted to bool.
  `a || b` is `(let %r bool true)`, `(if A (then) (else B' (set %r B')))`.
- `a , b` evaluates `a` for effect, then yields `b`. It needs no branch.

Evaluation order. C++ sequences `,`, `&&`, `||` and the condition of `?:` fully. For the other operators most of the
order is unspecified, and the lowering picks one: operands of a binary operator are evaluated left to right, call
arguments left to right, and the right operand of a compound assignment before its left lvalue (C++17 requires that
one). The choice is ours, not EDG's, and it is part of the IR's semantics.

**(e)** Integer arithmetic has two families:

- `w` (wrapping): `wadd wsub wmul wneg`. Two's complement, defined for every integer type. Unsigned arithmetic always
  uses these.
- `c` (checked): `cdiv crem` trap on a zero divisor, and on `INT_MIN / -1` for signed types. `cshl cshr` trap when the
  count is negative or not less than the bit width of the left operand's type. `cf2i` traps when the operand is NaN or
  the truncated value does not fit the target type. `bounds IDX N` traps unless `0 <= IDX < N`. `nonnull P` traps when P is
  null. `unreachable` traps.
- `cadd csub cmul cneg`: checked forms for signed overflow. **Not emitted by default.** Signed `+ - *` and unary `-`
  wrap (`wadd` etc.), because `tests/cases/signed_overflow_wraps.cpp` states that nfcxx must give signed overflow
  wrapping semantics. `NFCXX_IR_OVERFLOW=trap` switches them to `c*` ops, which trap on overflow; that is the
  UB-free choice when wrapping is not wanted.
- Float ops (`fadd fsub fmul fdiv fneg`) are IEEE binary and never trap.

Division truncates toward zero and `crem` takes the sign of the dividend, as in C++. The shift family is defined on the
bit pattern: `cshl` shifts left in two's complement, `cshr` is arithmetic for signed and logical for unsigned types.

Joins and traps are explicit statements, so a backend that does not check (for example a plain C target) must either
emit the checks or refuse the program. Nothing is silently dropped.

## 5. Decision (f): explicit address arithmetic

Pointer and aggregate addressing has no C-level expression:

- `(offset ADDR N)`: field access. `N` is `a_field.offset` from EDG (bytes). Bit-fields are not lowered yet.
- `(index BASE IDX SIZE)`: `BASE + sext(IDX) * SIZE`, wrapping. `SIZE` is `f_size_of_type` of the element. `padd`,
  `psubtract` and subscripts use it. Subtraction negates the index with `wneg` first.
- `(pdiff A B SIZE)`: `(A - B) / SIZE` in the pointer difference type.
- `(bitcast PT OP)`: change of pointee type with the same address. Array decay and `&` produce one.
- `(bounds IDX N)`: emitted before a subscript when the base is `array_to_pointer` of an array of known length. Pointers
  carry no length, so a subscript through a pointer is unchecked (see 9).
- `(nonnull P)`: emitted before every dereference of a pointer value (`indirect`, `points_to_field`). Addresses of objects
  are not checked.

All sizes and offsets come from EDG's layout (`a_field.offset`, `f_size_of_type`), not recomputed.

## 6. Decision (g): the text form

S-expressions, one statement per line, indented by nesting. Identifiers are double-quoted strings. The grammar as printed:

```
module    ::= (ir-module "FILE") global* data* function*
global    ::= (global "NAME" TYPE)                        static storage object (no initializer yet)
data      ::= (data "NAME" TYPE CONST)                    string literal: CONST = (string "...")
function  ::= (function "LINKAGE" (ret TYPE|void) (params PARAM*) [(static)] SLOT* STMT*)
PARAM     ::= (sret %N TYPE) | (param %N "NAME" TYPE) | (param %N "NAME" (byval TYPE)) | (ellipsis)
SLOT      ::= (slot "NAME" TYPE)
STMT      ::= (let %N TYPE RVALUE) | (set %N OPERAND) | (store[.v] TYPE ADDR VALUE) | (copy BYTES DST SRC)
            | (eval RVALUE) | (bounds OPERAND N) | (nonnull OPERAND)
            | (if OPERAND (then STMT*) [(else STMT*)]) | (loop (body STMT*) (step STMT*))
            | (switch OPERAND (body STMT*)) | (case CONST) | (default) | (break)
            | (goto "L") | (label "L") | (return [OPERAND]) | (unreachable) | (block STMT*)
RVALUE    ::= OPERAND | (load[.v] TYPE ADDR) | (offset ADDR N) | (index BASE IDX SIZE) | (pdiff A B SIZE)
            | (wadd|wsub|wmul T A B) | (wneg T A) | (cadd|csub|cmul|cdiv|crem|cshl|cshr T A B) | (cneg T A)
            | (fadd|fsub|fmul|fdiv T A B) | (fneg T A) | (and|or|xor T A B) | (not T A)
            | (eq|ne T A B) | (lt.s|lt.u|lt.f|le.s|le.u|le.f T A B)           result type bool
            | (iconv|bitcast|i2p|p2i|cf2i|i2f|u2f|fconv TYPE A)               conversions
            | (call TYPE CALLEE ARG*) | (eval (call void CALLEE ARG*))
OPERAND   ::= %N | $"name" | @"name" | &"name" | (const TYPE VALUE) | (null PTR)
TYPE      ::= int | unsigned_int | bool | double | ... | void | (ptr TYPE) | (struct "N") | (class "N") | (union "N")
            | (array N TYPE) | (fn RET (PARAMS))   [type text as in stage 1; qualifiers are kept inside pointee and object types]
```

Unsupported nodes print as `(unsupported KIND NAME)` in place of the statement or of the register's right-hand side.
The runner counts them.

The format is meant to be parsed by the Lean side without the C++ front end: every construct is an s-expression, every
operand is typed by its declaration, and every trap condition is a statement or a named operator in section 4. The
text form is not yet parsed by anything.

## 7. Requirements for QBE

QBE IL is SSA over basic blocks, typed as `w l s d` with extension loads (`loadsb`, `loadub`, ...), and it has no
exceptions, volatile or `long double` (cproc does not support those). The IR maps onto it as follows:

- Structured `if`, `loop`, `switch`, `goto` become blocks and jumps. `break` and `continue` become jumps to the loop
  exit and the `step` block.
- Registers become SSA values through mem2reg-style conversion, or stack slots (`alloc`) when they are assigned in
  several places. Slots map to `alloc4`/`alloc8`.
- Checked ops become a compare, a conditional jump to a shared `abort` block (`cdiv` also tests `INT_MIN / -1`), and
  the operation. `cshl`/`cshr` need the count range test; QBE's shift semantics for out-of-range counts are not
  relied on.
- `wadd`/`wsub`/`wmul` map to QBE `add`/`sub`/`mul` on `w` or `l`. Signed and unsigned comparisons use QBE's `s`/`u`
  forms. Narrow integer types are widened with `extsb`/`extub`/... at loads and conversions.
- `volatile` (`load.v`, `store.v`) has no QBE equivalent: QBE does not order or preserve volatile accesses, so these
  must be refused or lowered to a runtime call. This is the same gap cproc has, and it is needed for MMIO on the
  Hexagon target.
- `copy` maps to a call to `memmove` or an inline sequence of loads and stores for small sizes.

## 8. Requirements for SPIR-V and WGSL

- **Control flow.** `if` and `loop` (with `step` as `continuing`) map directly. `break` maps to `break`. `switch` with
  fallthrough must be split by the structurizer; WGSL `switch` supports `fallthrough` only as the last statement of an
  arm. `goto` must be removed entirely before emission.
- **Address spaces.** Stack slots (`$"x"`) are the `function` address space. Static objects (`@"x"`) need an explicit
  space: `private` for module-scope variables, `storage` or `uniform` for buffers. The current text form does not carry
  a space on `global`; a `(space S)` attribute is needed before GPU emission.
- **Pointers.** WGSL has no pointer arithmetic and no pointers stored in memory. `index` and `offset` must be turned
  into array indexing on a known buffer, so the GPU path needs the element type and the base object at each `index`.
  The text form already gives both (the operand's type and its base operand); the GPU lowering must reject any base that
  is not a slot, a global or a function parameter of known array type.
- **Traps.** GPUs have no trap. `bounds`, `nonnull`, the `c*` ops and `unreachable` need a defined GPU behaviour, such as
  clamping or an error flag written to a buffer. This is a policy decision for the GPU back end, not a property of the IR.
- **Types.** `long double`, `bool` in memory and 64-bit integers are restricted on GPU targets. The IR keeps them; the
  target rejects them.

## 9. Status, limits, and coverage

Implemented in `be/nfcxx_ir.c` (run `tests/pathb-ir/run.sh`):

- All statements of the stage 1 subset that appear in `tests/cases`: `block`, `expr`, `if`, `while`, `do-while`, `for`,
  `switch` with case markers, `goto`, `label`, `return`, `decl`, `init` (`constant`, `expression`), `empty`.
- Expressions: integer and pointer arithmetic (`wadd`, `wsub`, `wmul`, `cdiv`, `crem`, `cshl`, `cshr`, bitwise ops,
  `index`, `offset`, `pdiff`), floating arithmetic, comparisons, `?:`, `&&`, `||`, comma, assignments and compound
  assignments, `++`/`--` (pre and post), casts (integer, bool, float, pointer, `void`), calls (direct, through function
  pointers, aggregate arguments and results), `address_of`, `array_to_pointer`, `indirect`, `dot_field`,
  `points_to_field`, `subscript`, `lvalue_adjust`, `class_rvalue_adjust`, locals, parameters, globals, string literals,
  integer, float and address constants, aggregate initializers for arrays, structs, classes and their bases
  (direct bases first, then members, as EDG's aggregate constants are ordered).

Not implemented (each prints an `(unsupported ...)` marker or is a stated decision):

1. **Reachability.** The routine set is stage 1's: every defined body that the front end marks needed, including the
   unreferenced inline and constructor bodies stage 1 noted. Stage 2 does not compute reachability yet.
2. **Global initializers.** File-scope variables are printed as `(global "NAME" TYPE)` with no initializer. Vtables and
   other static data therefore have no contents in the IR. This is a gap for any backend that links the program.
3. **Constructor initializers** (`dik_constructor`), VLAs, GNU statement expressions, inline asm and bit-field
   access print unsupported markers. None of these appears in `tests/cases` after lowering.
4. **`continue`** is not a node. The lowered IL turns it into `(goto "L")` to a `(label "L")` at the end of the loop
   body, and the IR keeps that goto. It is correct but unstructured: a structurizer has to turn it back into a `continue`
   (the `step` of `loop`) before WGSL emission. The tests do not contain `continue`; the probe in section 9 does.
5. **Loads of `bool`** are not normalized. A bool object holding a value other than 0 or 1 is undefined here.
6. **Pointer subscripts are not bounds-checked** (no length), and **pointer dereferences are null-checked** only when the
   pointer is not an address constant.
7. **Uninitialized reads** of slots are unspecified; the IR has no `undef` yet.
8. **Thread-local objects** are treated like static objects.
9. **Indirect calls** through a null function pointer are not checked explicitly; the rule in section 4 applies once a
   `nonnull` is emitted before the call.
10. **No SSA, no mem2reg, no constant folding.** The output is correct but verbose: every named variable is a slot.

Coverage on `tests/cases` (10 programs; NFCXX_PATHB_STATS counts every node the lowering visits):

| Class (EDG kind table) | Named in `be/nfcxx_names.h` | Referenced by the lowering | Seen in `tests/cases` |
| --- | --- | --- | --- |
| operators (`eok_*`) | 122 | 54 | 28 |
| statements (`stmk_*`) | 34 | 15 | 9 |
| expression nodes (`enk_*`) | 42 | 4 (`constant`, `variable`, `routine`, `object_lifetime`) | 3 |
| constants (`ck_*`) | 19 | 4 (`integer`, `float`, `address`, `string`) and aggregates inside initializers | 3 |
| dynamic inits (`dik_*`) | 8 | 2 (`constant`, `expression`) | 2 |

On the ten programs, `tests/pathb-ir/run.sh` reports 1926 node occurrences visited, all lowered, 0 `(unsupported ...)`.
The 45 kinds seen are all lowered. "Referenced" is a count of the `case` labels in `be/nfcxx_ir.c`; it is not a test of
behaviour. The kinds in the table's third column that are not in the fourth are implemented but not exercised by these
programs. The probe in `tests/pathb-ir/gaps.cpp` exercises the marker path on purpose: a variable-length array (2
statement kinds), a GNU statement expression, inline asm, and bit-field reads and writes give 8 `(unsupported ...)`
markers, which the runner checks against the expected count.

Reproduce (from the worktree; the harness is built out of tree):

```
PATHB_OUT=/some/scratch/dir scripts/setup-pathb.sh        # build cpfe outside build/ (see below)
export PATHB_CPFE=/some/scratch/dir/cmake/bin/cpfe PATHB_BASE=/some/scratch/dir/edg-base
scripts/pathb-dump --ir tests/cases/hvx_add_i16.cpp     # the IR of one program
tests/pathb-ir/run.sh                                   # all goldens and the coverage summary
tests/pathb-ir/run.sh --update                          # rewrite goldens after an intended change
NFCXX_IR_OVERFLOW=trap scripts/pathb-dump --ir tests/cases/signed_overflow_wraps.cpp   # checked signed ops
```

`PATHB_OUT` moves the harness build away from `build/pathb`, which in a worktree is a symlink into the main checkout.
