# Path B stage 2: the mid-level IR

Status: first implementation. `be/nfcxx_ir.c` lowers the lowered EDG IL of `tests/cases/*.cpp` to the IR below and
prints it, with no unsupported nodes on those programs. Goldens: `tests/pathb-ir/*.ir`, checked by
`tests/pathb-ir/run.sh`. Stage 3 adds the first consumer, an IR-to-QBE emitter
(`scripts/pathb-qbe-emit.rb`, see `docs/notes/pathb-stage3.md`). There is still no SPIR-V or WGSL emitter, no
checker, and no execution of the IR itself. Sections 1-8 are the spec; section 9 says what is implemented, what
is not, and the coverage numbers.

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
| `(loop (body S...) (step S...))` | repeat { body; L_cont: step }. `(break)` leaves the loop. `(continue)` jumps to `step` (stage 3 round 2; before it was a `goto`, see 9) |
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

- `(offset ADDR N)`: field access. `N` is `a_field.offset` from EDG (bytes). Bit-fields are different, see 5a.
- `(index BASE IDX SIZE)`: `BASE + sext(IDX) * SIZE`, wrapping. `SIZE` is `f_size_of_type` of the element, a number, or
  a register (of type `unsigned_long`) when the element type is a variable-length array type (5b). `padd`,
  `psubtract` and subscripts use it. Subtraction negates the index with `wneg` first.
- `(pdiff A B SIZE)`: `(A - B) / SIZE` in the pointer difference type. `SIZE` as for `index`.
- `(bitcast PT OP)`: change of pointee type with the same address. Array decay and `&` produce one.
- `(bounds IDX N)`: emitted before a subscript when the base is `array_to_pointer` of an array of known length. Pointers
  carry no length, so a subscript through a pointer is unchecked (see 9).
- `(nonnull P)`: emitted before every dereference of a pointer value (`indirect`, `points_to_field`). Addresses of objects
  are not checked.

All sizes and offsets come from EDG's layout (`a_field.offset`, `f_size_of_type`), not recomputed.

### 5a. Bit-fields

A bit-field is not an addressable object, so the IR has two operations on the *storage unit* that holds it:

- `(bfload T UNIT ADDR BOFF WIDTH)` (an RVALUE): reads the `UNIT`-byte integer at `ADDR` (little-endian, `UNIT` is 1, 2,
  4 or 8) and extracts bits `BOFF .. BOFF+WIDTH-1`. The result has the integer type `T`: sign-extended when `T` is signed,
  zero-extended otherwise (`bool`: the bits, 0 or 1 for a 1-bit field).
- `(bfstore T UNIT ADDR BOFF WIDTH VALUE)` (a STMT): a read-modify-write of the same unit. The low `WIDTH` bits of `VALUE`
  (which has type `T`) replace those bits; every other bit of the unit is written back unchanged. The store does not
  report the truncated value; the lowering reads the field again with `bfload` when the value of the assignment is
  used (`result_is_not_used` is false).

The `.v` forms (`bfload.v`, `bfstore.v`) are the volatile accesses. `ADDR` is the address of the storage unit (not of
the struct), computed with `offset` like any member. `T` is the declared type of the field with the field's own
signedness (EDG `bit_field_is_signed`): an unsigned enumeration bit-field prints as `unsigned_int`, not the signed
`int` that the enumeration's type text gives. A load or store narrower or wider than `T` is allowed (`T` may be 8 bytes
with a 4-byte unit); the value is converted.

Layout comes from EDG: `a_field.offset` (bytes) and `offset_bit_remainder` (0..7) give the bit position of the field in
its parent, `bit_size` the width. The lowering picks the unit as follows: the declared type's size `U`, at the
`U`-aligned offset that contains the field, when the field fits there and the unit lies inside the parent object (the
usual case; gcc does the same). Otherwise it tries 1, 2, 4 and 8 bytes at an aligned offset, then the window of that
size that ends at the end of the parent (a packed struct, a field that straddles its declared type). A field that
fits no window is `(unsupported lvalue bit-field-layout)`. **Wider than 64 bits:** EDG truncates a width that exceeds
the declared type (`long long c : 70` is a 64-bit field with the warning "truncated to 64 bits"), so only a 128-bit
declared type (`unsigned __int128 f : 100`, a GNU extension) can be wider than 64 bits. Such an access prints
`(unsupported lvalue bit-field-wider-than-64-bits)`. It cannot be lowered in any case: the emitter has no 128-bit
type (`refused: type __uint128_t`), and `UNIT` is at most 8 bytes.

Compound assignment and `++`/`--` are `bfload`, the arithmetic in the declared type `T` (so it wraps in `T`, then the
store truncates to `WIDTH`), `bfstore`. Initialization: aggregate initializers store each named bit-field with `bfstore`
(unnamed bit-fields take no initializer); a static initializer lists one item per bit-field,
`(bitfield OFF UNIT BOFF WIDTH T (const T V))` with `OFF` the byte offset of the unit, and the consumer ORs the bits of
all items together (fields of different declared types have overlapping units, so merging is by bit position).
Bit-fields in unions work in aggregate initializers too (below). A class with a virtual base never has an aggregate
constant: its constructor cannot be `constexpr` (EDG: "a constructor for a class with virtual bases cannot be
constexpr"), so such an object is zero-initialized at start-up (`(zero 0 N)`) and constructed dynamically, and its
bit-fields are written by the constructor with `bfstore`. `ir_class_members` still returns -1 for a virtual base, and
the `(unsupported init virtual-base)` marker stays as a guard that no program reaches.

**Union aggregate constants.** `U u = {5}` and the union members of structs and arrays are `ck_aggregate` constants
whose list holds the initialized member: an optional `ck_designator` naming the field, else the first non-empty
initializable field (`next_applicable_field`, EDG's own rule in `dump_initializer_part`), then its value, or nothing for
`{}`. A local object zeroes the whole union first (stores of 8, 4, 2 or 1 bytes; skipped when the member covers the
union), then stores the member (a bit-field member with `bfstore`). A static initializer prints the member's items at
its offset (a bit-field as a `(bitfield ...)` item) followed by `(zero OFF N)` for the remaining bytes. Zeroing an
aggregate (`ir_zero_object`) is no longer `(unsupported init zero-aggregate)` for objects of up to 128 stores.

**`eok_bassign`** (block assignment): IL lowering copies a static array into an array member when a default member
initializer is `int arr[3] = {1, 2, 3};` (a class with a base class and a vptr hits this in every constructor). It
lowers to `(copy N DST SRC)`, `N` the size of the source operand; the result is void.
The emitter documents its code shape in `scripts/pathb-qbe-emit.rb` (`r_bfload`): extraction is a shift pair, never an `and`
with a low mask, because QBE's width analysis drops such a mask wrongly in some loops (see `docs/notes/pathb-stage3.md`).

### 5b. Variable-length arrays

EDG keeps VLAs in the lowered IL as three things, and the IR follows them:

- `stmk_set_vla_size`: evaluates a dimension expression once into a compiler variable (`dimension_variable`). The IR
  lowers the dimension expression (an assignment to that variable), so the dimension is an ordinary local slot.
- an expression statement EDG adds that assigns the total element count (all dimensions multiplied, in `ptrdiff_t`)
  to `vla_element_count_variable`;
- `stmk_vla_decl`: the point where the storage appears. It prints `(vlaalloc $"v" BYTES)`:
  `BYTES` (an `unsigned_long` operand) is the count times the size of the innermost element type.

The VLA variable `v` has no slot of its own with the array's size. Its slot `(slot "v" (ptr (array ? T)) 8 8)` holds the
*address* of its storage, and every use of the variable loads that pointer first, so `$"v"` is the slot of the pointer,
not the array. `(array ? T)` is how a VLA type prints (the `?` is the unknown count).

**Current harness: EDG lowers the VLA itself** (`LOWER_VARIABLE_LENGTH_ARRAYS=1` in the macro config that
`scripts/setup-pathb.sh` writes; the C generator's configuration has it, the default for a non-C back end does not).
Then none of the above reaches the IR. A VLA variable is an ordinary `T *` local, `stmk_vla_decl` becomes an
expression statement `(eval (call void &"__vla_alloc" (bitcast &v) BYTES))` at the declaration, and EDG puts
`(eval (call void &"__vla_dealloc" ...))` at **every** exit from the scope: the end of the block, `break`, `continue`,
`goto` and `return` that leave it, and on exceptions an entry of the destruction list that calls `__vla_dealloc_eh`
(the function-local `(array N (struct "__C8"))` EH tables name it). `__vla_alloc`/`__vla_dealloc` are in EDG's
run-time library (`lib_src/vla_alloc.c`, in `libC.a`, which the Path B tests already link): a pool over `malloc` that
also frees allocations made dead by a `longjmp`. This is what the earlier note below asked for: a scope-exit marker.
Probe: `tests/pathb-qbe/cases/vla_scope.cpp` counts the live allocations with `__vla_number_of_active_allocations()`
after blocks, nested blocks, loops with `break`/`continue`, a backward and a forward `goto`, early `return`, `switch`,
recursion, large blocks in a loop and a function whose destructor runs next to a VLA. Limits: the pool is a single
global (the runtime says it is not thread safe), and each VLA costs two calls and a `malloc`ed block instead of a
`sub rsp`. `be/nfcxx_ir.c` keeps the code for the unlowered configuration under `#if !LOWER_VARIABLE_LENGTH_ARRAYS`.

**Unlowered configuration (`vlaalloc`).** `(vlaalloc $"slot" BYTES)`: allocate `BYTES` bytes of dynamic stack storage,
16-byte aligned, uninitialized, and store the
address in the slot. **Lifetime.** EDG gives no scope-exit marker for a VLA in that configuration (the lowered IL
has no `enk_vla_dealloc` in C++ mode, where deallocation is an entry of the destruction list, and EDG creates that
entry (`is_vla_deallocation`) only when `VLA_DEALLOCATION_REQUIRED` is true, which it is only with
`LOWER_VARIABLE_LENGTH_ARRAYS`). The IR therefore does not free at the end of the block. The
semantics are: the storage lives until the function returns, *or* until the same `vlaalloc` executes again, when the
old array's lifetime has ended anyway (C and GNU C end it when execution leaves the block, including a backward `goto`),
and the backend may reuse the space. A backend with no dynamic stack must refuse the statement. The QBE emitter keeps a
capacity per `vlaalloc` and allocates only when `BYTES` exceeds it (then for `max(BYTES, 2 * capacity)`), so a loop
that declares a VLA of at most N bytes uses O(N) stack, not O(N * iterations); a recursion with a VLA uses one
allocation per frame, released at return. Even with a marker the stack could not be released: QBE has no stack
save/restore (`alloc16` outside `@start` is a bare `sub rsp`, and QBE offers no way to read or set `rsp`), which is
why the lowered form, heap based, is the way to free at scope exit.

`sizeof` of a VLA type or expression (`enk_sizeof` that EDG could not fold) is the product of the dimension variables
and the element size, computed in registers, and so is the stride of a pointer to a VLA row (`index`/`pdiff` take a
register `SIZE`). No `bounds` check is emitted for a VLA subscript (the length is a run-time value, and `bounds`
takes a number). VLA typedefs (`stmk_vla_decl` with `is_typedef_decl`) allocate nothing; a function parameter of VLA
type is a pointer as in C++ and needs nothing.

### 5c. GNU statement expressions

`({ S...; E; })` (`enk_statement`) is lowered inline: the statements run in place (no `(block)` wrapper, so the
registers they define stay visible), and the value is the last statement when it is an expression statement
(EDG marks it `stmk_stmt_expr_result`; its expression is lowered like any rvalue). A void result, or a statement
expression whose last statement is not an expression, has no value. `break`, `continue`, `goto` and `return` inside work as in
any statement. **A class result** that IL lowering copies out of the block with a copy constructor does not end the block
with `stmk_stmt_expr_result`: the block holds the locals' constructors, a nested statement expression in an ordinary
expression statement (its block copy-constructs the result into the destination object, and its own last statement
names that object), and then the destructor calls of the locals. The value statement is therefore the last statement of
the block, or, when the statement expression has a class type, the last expression statement whose expression is itself
a statement expression (`ir_stmt_expr`); the cleanup statements after it are lowered in order, after the value was
computed. The value is the address of the destination object. `tests/pathb-qbe/cases/stmtexpr_class.cpp` compares
copy and destructor counts with the gcc backend. A `stmk_stmt_expr_result` that still carries a `dynamic_init` (expr
NULL) stays `(unsupported stmt stmt_expr_result)`; this EDG build did not produce one in any probe.

**Inline asm** (`stmk_asm`). QBE has no inline assembly, so only the subset that does nothing but constrain the compiler
is lowered: an empty template (blank characters only), no operands, no labels, clobbers `"memory"` and/or `"cc"`, or a
basic `asm("")` (gcc treats a basic asm as clobbering memory). With the `"memory"` clobber (or a basic asm) it prints
`(barrier)`, a compiler barrier; without it, the statement prints nothing (it constrains no memory). Everything else
prints `(unsupported stmt REASON)` with `REASON` one of `asm-template` (a non-empty template), `asm-operands`
(inputs or outputs), `asm-clobbers` (a register clobber) or `asm-goto`, and the emitter refuses the module with that
text (`refused: (unsupported stmt asm-operands)`; it used to say only `statement (unsupported ...)`). An asm with outputs
or a template cannot be implemented on QBE at all: it would need an assembler template inserted into QBE's output. The
emitter's `(barrier)` is a call of an empty module-local function `$__pathb_barrier` (emitted once per module with the
volatile helpers): QBE cannot look into a call or reorder it, and the call has no operands, so no stack slot escapes.

## 6. Decision (g): the text form

S-expressions, one statement per line, indented by nesting. Identifiers are double-quoted strings. The grammar as printed:

```
module    ::= (ir-module "FILE" (layout (short N) (int N) (long N) (long_long N) (pointer N) (float N) (double N) (long_double N))) global* data* (global|data|declare|function)*
declare   ::= (declare "NAME" (weak))                          a function declared __attribute__((weak)) that this module
                                                               refers to and does not define: a weak reference (see Linkage)
global    ::= (global "NAME" TYPE BYTES ALIGN [(static)|(weak)|(weak attr)] [(thread)] INIT)
                                                               static storage object; (static) = internal linkage,
                                                               (weak) = COMDAT/weak definition, or, with INIT (extern),
                                                               a declaration with __attribute__((weak)) (weak reference),
                                                               (weak attr) = a definition with __attribute__((weak)),
                                                               (thread) = thread storage duration (one copy per thread)
INIT      ::= (extern)                                    declared here, defined elsewhere: no storage
            | (init ITEM*)                                 static initializer (see ITEM)
            | (unsupported init KIND)                      not lowered (dynamic initialization)
ITEM      ::= (scalar OFF TYPE (const TYPE V)|(null PTR))  one number, at byte offset OFF
            | (bitfield OFF UNIT BOFF WIDTH TYPE (const TYPE V))  bits BOFF.. of the UNIT-byte unit at byte OFF (5a);
                                                           items that share bits of a byte are ORed together
            | (addr OFF TYPE TARGET ADD)                   address TARGET (@"x" or &"f") plus byte addend ADD
            | (bytes OFF BYTES @"const")                   the bytes of a string literal copied into an array
            | (zero OFF BYTES)                             elements the initializer does not name
data      ::= (data "NAME" TYPE CONST)                    string literal: CONST = (string "...")
function  ::= (function "LINKAGE" (ret TYPE|void) (params PARAM*) [(static)|(weak)|(weak attr)] [(constructor [PRIO])]
              [(destructor [PRIO])] SLOT* STMT*)       PRIO = 1..65535; (constructor)/(destructor): see "Start-up and exit"
PARAM     ::= (sret %N TYPE) | (param %N "NAME" TYPE) | (param %N "NAME" (byval TYPE)) | (ellipsis)
SLOT      ::= (slot "NAME" TYPE BYTES ALIGN)
STMT      ::= (let %N TYPE RVALUE) | (set %N OPERAND) | (store[.v] TYPE ADDR VALUE) | (copy BYTES DST SRC)
            | (zero-fill BYTES DST)                                         clear an aggregate
            | (bfstore[.v] TYPE UNIT ADDR BOFF WIDTH VALUE)                  bit-field store (5a)
            | (vlaalloc $"SLOT" OPERAND)                                    VLA storage (5b)
            | (eval RVALUE) | (bounds OPERAND N) | (nonnull OPERAND)
            | (if OPERAND (then STMT*) [(else STMT*)]) | (loop (body STMT*) (step STMT*))
            | (switch OPERAND (body STMT*)) | (case CONST) | (default) | (break)
            | (goto "L") | (label "L") | (return [OPERAND]) | (unreachable) | (block STMT*)
            | (barrier)                                                    compiler barrier (asm volatile("" ::: "memory"))
RVALUE    ::= OPERAND | (load[.v] TYPE ADDR) | (offset ADDR N) | (index BASE IDX SIZE) | (pdiff A B SIZE)
            | (bfload[.v] TYPE UNIT ADDR BOFF WIDTH)                         bit-field load (5a)
            | (wadd|wsub|wmul T A B) | (wneg T A) | (cadd|csub|cmul|cdiv|crem|cshl|cshr T A B) | (cneg T A)
            | (fadd|fsub|fmul|fdiv T A B) | (fneg T A) | (and|or|xor T A B) | (not T A)
            | (eq|ne T A B) | (lt.s|lt.u|lt.f|le.s|le.u|le.f T A B)           result type bool
            | (iconv|bitcast|i2p|p2i|cf2i|i2f|u2f|fconv TYPE A)               conversions
            | (call TYPE CALLEE [(variadic N)] ARG*) | (eval (call void CALLEE [(variadic N)] ARG*))
OPERAND   ::= %N | $"name" | @"name" | &"name" | (const TYPE VALUE) | (null PTR)
TYPE      ::= int | unsigned_int | bool | double | ... | void | (ptr TYPE) | (struct "N") | (class "N") | (union "N")
            | (array N TYPE) | (array ? TYPE) | (fn RET (PARAMS))   [type text as in stage 1; qualifiers are kept inside pointee and object types]
SIZE      ::= N | %N        a byte count: a number, or a register of type unsigned_long (a VLA element type)
```

`(variadic N)` appears in a call whose callee's function type ends in `...` (a direct call or one through a
function pointer). `N` is the number of leading `ARG`s that match named parameters, the hidden `sret` pointer included;
the remaining arguments are the variadic ones (already promoted by the front end). A backend must pass the variadic
ones with the variadic calling convention (QBE: `...` after the N-th argument, so `%al` is set for the callee). A call
without the marker is a call of a prototyped, non-variadic callee. A definition's own `...` is the `(ellipsis)` parameter.

Linkage. Without a marker a definition is external (strong). `(static)` is internal. `(weak)` marks a definition that EDG
puts in a COMDAT group: `a_routine.use_comdat` for functions (inline functions, template instances, implicit members)
and `a_variable.comdat_group != NULL` for variables (inline variables, function-local statics of such functions,
vtables, typeinfo). These are the objects `c_gen_be.c` writes with `__attribute__((__weak__))` and that
`scripts/weak-symbols.rb` finds in the production path. Every translation unit that needs one defines it; the
definitions are identical and the link must keep one. A backend emits a weak symbol (ELF `.weak`, or COMDAT/linkonce).
A `(static)` object is never `(weak)`. A COMDAT definition that nothing in the module reaches may be dropped (another
unit has its own copy).

`__attribute__((weak))` (`is_weak` on a routine or variable) is carried in three forms. **A definition** is
`(weak attr)` (`(global ...)` and `(function ...)`): a weak symbol that is also an interface symbol, so, unlike a COMDAT
`(weak)`, it is kept when nothing in the module reaches it and a strong definition in another unit overrides it. **A
variable declaration** is `(global "x" T N A (weak) (extern))`: the object is defined elsewhere or not at all, its
address is a weak reference. **A function declaration** has no node of its own in the IR (an undefined function is
only an `&"f"` operand), so a weak one gets a top-level `(declare "f" (weak))`, printed once, when the module first
refers to the function (a call, an address, an address in an initializer). A weak routine that the module defines
needs no `declare`. The QBE emitter loads the address of a weak reference from the GOT (`extern $f`, `copy extern $x`),
so an absent definition reads as null in a PIE too, and marks the symbol `.weak`. This replaced the emitter's earlier
rule that every undefined function named `_ZTH*` is a weak reference: the `_ZTH<name>` thread-local initialization
function is a weak routine in EDG's IL and the lowering prints its `declare` like any other. `weakref` aliases
(`__attribute__((weakref("target")))`) name another symbol and are not handled.

Thread storage. `(thread)` follows the linkage marker (so `(global "x" int 4 4 (static) (thread) INIT)` is an internal
`static __thread int x`) and is printed for every variable with `var_has_thread_storage_duration`: `__thread`,
`thread_local`, a function-local `static thread_local`, and a declaration `extern thread_local int x;` (then with
INIT `(extern)`). The operand `@"x"` of a thread-local global is not an address of fixed storage: it is the address of
the current thread's copy and has to be computed at each use (it is the same for the whole lifetime of the thread,
but different between threads). Its initializer is the initial image every new thread starts from. The address of a
thread-local object is never an `(addr ...)` item of a static initializer (it is not a constant), and an emitter may
refuse one.

Dynamic initialization of thread-local objects. The IR carries no initializer record for it, as for static
storage: the lowering writes ordinary functions, and the consumer needs nothing special except that every one of them is
printed. `__tls_init` (static) runs the constructors and the `__cxa_thread_atexit(dtor, &obj, &__dso_handle)`
registrations of the unit's thread-locals once per thread (a `static thread_local` guard). Each use of such a variable is
a call of its wrapper `_ZTW<name>()`, a function that calls `_ZTH<name>()` and returns the object's address
(`(weak)` unless `(static)`: every unit that uses the variable defines it). `_ZTH<name>` is a function
`(function "_ZTH.." (ret void) (params) [(static)|(weak)] (eval (call void &"__tls_init")) (return))` in the unit that
defines the variable, and an undefined function in a unit that only declares it (a weak reference: its wrapper tests
the address first). See stage 3, "Dynamic initialization of thread-local objects".

Volatile. A volatile lvalue is loaded with `(load.v TYPE ADDR)` and stored with `(store.v TYPE ADDR VAL)`; the TYPE is
the unqualified scalar type. An access is volatile when the object it reads or writes is volatile: a variable whose
declared type is volatile, a member of a volatile object, a volatile member, an element of a volatile array, or an
object reached through a pointer whose pointee type is volatile. (EDG drops cv-qualifiers from the node type of an
rvalue use, so the lowering derives the flag from the declaration, the base object and the pointer's pointee type,
not from the node type.) Object and pointee types keep their `(volatile ...)` wrapper in type text, so an emitter must
accept `(volatile T)` wherever `(const T)` is accepted. A `(load.v ...)`/`(store.v ...)` must happen exactly once and
in program order with respect to the other volatile accesses and calls; it must not be merged, removed or reordered
across another volatile access. Aggregate copies `(copy N DST SRC)` of volatile objects are not marked (a copy is
a call of a memory-copy routine in the QBE emitter, which a compiler cannot elide).

Start-up and exit. `(constructor [PRIO])` on a function means it runs before `main`; `(destructor [PRIO])` means it
runs at exit (a function may carry both). They come from two sources, and the IR does not say which:

- `__attribute__((constructor [(PRIO)]))` and `__attribute__((destructor [(PRIO)]))` (EDG `is_initialization_routine`
  with `ctor_priority`, `is_finalization_routine` with `dtor_priority`).
- The initialization routine that IL lowering makes for a translation unit, named `__sti__...`
  (`IL_LOWERING_INIT_ROUTINE_PREFIX`). It runs every dynamic initializer of the file scope in source order: the
  constructor calls, `__cxa_atexit(dtor, &obj, &__dso_handle)` registrations (so static objects are destroyed in
  reverse order of construction at exit, by the C library, and nothing else is needed for destructors of statics) and
  the stores of values computed by calls. A GNU `init_priority(N)` object gets a second `__sti__...__prioN` routine,
  which carries `(constructor N)`. This is the routine the C back end marks `__attribute__((constructor))` (path A),
  or puts in a `.ctors.(65535-N)` section for a priority. Variables with dynamic initialization are printed as
  zero-initialized `(global ... (init (zero 0 N)))`; the IR contains no other record of the dynamic initializer.

A routine with a marker is a root: a consumer must not drop it because no code refers to it (the function may be
`(static)`). Order: a routine with a PRIO runs before any routine without one, lower PRIO first; routines of equal
priority run in the order they appear in the module. Destructors run in the reverse order (a destructor without a
PRIO first). Function-local statics need no marker: the lowering writes the guard (`__cxa_guard_acquire` /
`__cxa_guard_release`; the guard is the C++ runtime's, as in path A), the constructor call
and the `__cxa_atexit` registration as ordinary statements of the function.

Unnamed routines. The lowering makes routines without a name (the helper that destroys an array with static storage,
registered with `__cxa_atexit`). They print as `__unnamed_fn`, `__unnamed_fn.1`, ... (the same name at the definition
and at every reference), and the name of every named routine is reserved first so that no static object, string or
unnamed routine takes it.

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
- `volatile` (`load.v`, `store.v`) has no QBE equivalent: QBE's optimiser forwards a store to a later load of the same
  address, merges equal loads and deletes unused ones (`load.c`, `gcm.c`), and it promotes a stack slot to a register
  when only loads and stores use it. The emitter lowers each volatile access to a call of a small helper function
  defined in the module (one real `load`/`store` inside), which QBE neither merges nor removes nor reorders, and whose
  address argument makes a slot escape. See `docs/notes/pathb-stage3.md`, "volatile".
- Thread-local objects (`(thread)`) become QBE `thread` data; every reference is `extern thread $x` (initial-exec
  through the GOT: valid for a definition in the same module, a declaration, and in a shared library). See stage 3,
  "thread-local".
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
2. **Global initializers** are done in stage 3. Each `(global ...)` carries its size and alignment and its
   INIT (section 6). The items are the element-wise form that `ir_init_constant` produces for locals, at byte offsets,
   in the same member and base order, with trailing array elements and class members the initializer does not name
   given as `(zero ...)`. Bytes no item covers are padding (zero). Function-local statics take their initializer from
   the function's local-static-variable-init entry (EDG `get_variable_initializer`). Dynamic initialization is still
   `(unsupported init dynamic)`, not lowered.
3. **Constructor initializers** (`dik_constructor`) and inline asm print unsupported markers. None of these appears in
   `tests/cases` after lowering. (Bit-fields, VLAs and GNU statement expressions were in this list; they are lowered
   since stage 3 round 3, sections 5a-5c; the later rounds closed the scope-exit free of a VLA, the class-result
   statement expression, union aggregate constants and the empty-asm barrier. Still open: no `bounds` check on VLA
   subscripts; bit-fields wider than 64 bits (128-bit declared type, not implementable); inline asm with a template,
   operands or register clobbers.)

   the function's local-static-variable-init entry (EDG `get_variable_initializer`). Dynamic initialization after
   lowering is explicit statements of the `__sti__` routine (see "Start-up and exit"), so a global never reaches
   `(unsupported init dynamic)` on the programs tested (that marker stays for an initializer kind the lowering left
   in the IL).
3. **Constructor initializers** (`dik_constructor`) in a `stmk_init` print as an ordinary constructor call
   `(eval (call void &"ctor" OBJ ARG*))`; the lowering expands every constructor into such a call before the
   back end sees it, so this path is never taken by the probes (array copies, implied copy sources and value
   initialization of the unlowered form stay unsupported). Inline asm beyond the barrier subset (5c) prints an
   unsupported marker. It does not appear in `tests/cases` after lowering.
4. **`continue`** is `(continue)` since stage 3 round 2. The lowered IL turns it into `(goto "L")` to an unnamed
   `(label "L")` at the end of the loop body; the lowering recognises that pair for the innermost loop, prints
   `(continue)` and drops the label. A goto to any other label stays a goto.
5. **Loads of `bool`** are not normalized in the IR; the QBE emitter normalizes them (nonzero is true).
6. **Pointer subscripts are not bounds-checked** (a pointer carries no length: `p[i]` has nothing to be checked
   against, see stage 3, "Decisions"), and **pointer dereferences are null-checked** only when the pointer is not an
   address constant. Subscripts of arrays, which have a length, are checked.
7. **Uninitialized reads** of slots are unspecified; the IR has no `undef` (decision and reasons in stage 3).
8. **Thread-local objects** are marked `(thread)` since stage 3 round 3.
9. **Indirect calls** through a null function pointer are checked: the lowering prints `(nonnull F)` before the call
   (a call through a function pointer, including the lowered form of virtual calls and calls through a pointer member),
   unless the callee operand is an address constant. This closes the gap.
10. **No SSA, no mem2reg, no constant folding.** The output is correct but verbose: every named variable is a slot.
11. **C++ exceptions** need no IR construct. EDG lowers try/catch/throw/cleanups/exception specifications to its setjmp/longjmp
    ABI before the back end runs, so the IR holds a call of `_setjmp` on a slot of the EH stack entry type, calls of
    `__throw_setup`, `__throw`, `__rethrow`, `__exception_caught` and `__destroy_exception_object`, stores to the globals
    `__curr_eh_stack_entry`, `__eh_curr_region`, `__catch_clause_number` and `__caught_object_address`, and static region/catch tables
    and typeinfo globals. The lowering handles the two nodes that EH programs added: `enk_result_of_overriding_function` (the body of a
    this-adjusting thunk, printed as a `(call ... &"underlying" PARAMS...)` with the thunk's own parameters) and a function designator
    as an lvalue (`&"f"`). The runtime is EDG's `libC.a` (`lib_src/throw.c`); a consumer must keep every slot of a function that calls
    `_setjmp` in memory (the QBE emitter does). Details, probes and limits: `docs/notes/pathb-stage3.md`, "C++ exceptions".

Coverage on `tests/cases` (10 programs; NFCXX_PATHB_STATS counts every node the lowering visits):

| Class (EDG kind table) | Named in `be/nfcxx_names.h` | Referenced by the lowering | Seen in `tests/cases` |
| --- | --- | --- | --- |
| operators (`eok_*`) | 122 | 54 | 28 |
| statements (`stmk_*`) | 34 | 15 | 9 |
| expression nodes (`enk_*`) | 42 | 4 (`constant`, `variable`, `routine`, `object_lifetime`) | 3 |
| constants (`ck_*`) | 19 | 4 (`integer`, `float`, `address`, `string`) and aggregates inside initializers | 3 |
| dynamic inits (`dik_*`) | 8 | 2 (`constant`, `expression`) | 2 |

On the ten programs, `tests/pathb-ir/run.sh` reports 1991 node occurrences visited, all lowered, 0 `(unsupported ...)`.
The 45 kinds seen are all lowered. "Referenced" is a count of the `case` labels in `be/nfcxx_ir.c`; it is not a test of
behaviour. The kinds in the table's third column that are not in the fourth are implemented but not exercised by these
programs. The probe in `tests/pathb-ir/gaps.cpp` exercises the marker path on purpose: it still contains a
variable-length array, a GNU statement expression and bit-field reads and writes (lowered now, so they appear in its
golden as `__vla_alloc` calls, plain statements and `bfload`/`bfstore`) and an inline asm with an input operand, which
is the one remaining `(unsupported stmt asm-operands)` marker; the runner checks the count (1). The probes
`tests/pathb-qbe/cases/{bitfield,bitfield2,bitfield_union,vla,vla_scope,stmtexpr,stmtexpr_class,agg_union,asm_barrier,weak_decl}.cpp`
have goldens of their own.

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
