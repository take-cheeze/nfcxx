# Path B: zero-cost exception handling

Status: in progress (opt-in, `PATHB_EH=tables`). The default Path B harness keeps EDG's portable EH lowering (an EH stack
of runtime frames in thread-local storage, `setjmp`/`longjmp` for `try`, EDG's runtime in `libC.a`).

## Why

The portable lowering pays on every call of a function with destructions, a `try` or a `noexcept` specification: a
frame is pushed and popped through `__curr_eh_stack_entry` (a `%fs` access), and `__eh_curr_region` is stored at each
cleanup region change. On llama.cpp's `ggml-vulkan.cpp` that was 4,172 noexcept frame stores and 6,337 `%fs` reads before
the frame elisions, and 1,107 frame stores and 3,234 `%fs` reads after them. gcc pays nothing on the normal path: the
unwinder reads tables (`.eh_frame`, the LSDA in `.gcc_except_table`) only when an exception is thrown.

## Design

The mode uses EDG's *partial lowering* EH scheme (`DO_FULL_PORTABLE_EH_LOWERING=0`, `GENERATE_EH_TABLES=1`):

- `try`, `catch` and `throw` stay in the IL (`stmk_try_block`, `enk_throw`), with `enk_lowered_eh_construct` nodes for
  what remains: the cleanup state (`leck_cleanup_state`, a region number), the function prologue (which points at the
  region and array tables), the address of the thrown and caught objects, and the catch epilogue.
- The region table is EDG's static description of the cleanups. Its entries form linked lists that already continue
  into outer lifetimes, and carry the destructor or `operator delete`, the object (a `ck_stack_offset` constant: a
  variable and an offset), and flags for a conditional construction (the flag variable is in the next entry), an
  indirect object, a `new` allocation, an array (element size and count in the array table), a VLA, a base-class
  subobject (and its VTT) and a local static's guard. EDG's runtime (`lib_src/throw.c`) interprets the table when a
  throw unwinds the function; Path B interprets it at compile time and writes the code into landing pads.

The "no lowering" scheme (both macros 0) was tried first and rejected: its cleanup states are destruction-list
positions whose chains stop at each lifetime, and lowering frees the descriptions of temporaries (their location and
conditional flag) before the back end runs, so a temporary's cleanup cannot be written from the IL.

### Back end (`be/nfcxx_ir_eh.h`)

- `leck_cleanup_state` sets the current region; a `try` pushes a frame that remembers the region at its entry. A landing
  pad is identified by (region, innermost frame); `(eh-state N)` in the body says that the calls after it unwind to pad N
  (0: through the function, or to `std::terminate` in a `noexcept` function).
- The pad's code walks the region chain from its region: each entry's cleanup, until the region at the entry of the
  innermost frame; then that frame (a `try`: a selector test for each catch clause, jumping to the handler; a `catch`:
  `__cxa_end_catch`); then on outwards. At the end it resumes the unwind (`_Unwind_Resume`), or calls `std::terminate`
  in a `noexcept` function.
- The pads share that code, as gcc's share their tails: a pad is a stub that keeps the exception and the selector and
  jumps to its node; a node (a region's cleanup, a frame's clauses, the end) is written once and jumps to the next one.
- `throw` is `__cxa_allocate_exception`, the lowered copy into it, `__cxa_throw` (typeinfo, destructor); `throw;` is
  `__cxa_rethrow`. A handler is `__cxa_begin_catch` on entry and `__cxa_end_catch` at the catch epilogue.
- The pad keeps the exception and the selector in two stack slots (`eh.exc`, `eh.sel`), which the handlers read.

### IR forms

- `(eh-types SYM-or-0 ...)`, `(eh-noexcept)`, `(eh-spec TID ...)`: function header; the catch clauses' typeinfo symbols
  (type ids from 1, 0 for `catch (...)`), and a C++14 `throw(T...)`'s allowed types.
- `(eh-state N)`: statement; the calls after it unwind to pad N (0: none).
- `(eh-pad N CLEANUP (TID ...) STMT ...)`: function level, after the body; the pad's catch clauses' type ids (the action
  chain) and whether it also cleans up. Its code ends in a jump to a handler's label, `std::terminate`, or
  `(eh-resume EXC)`.

`throw()` and `noexcept` are both `(eh-noexcept)`: a call with no pad has no call-site entry, so an exception that
reaches it calls `std::terminate`, and a pad of such a function cleans up and then calls it. With `(eh-spec ...)`
every state has a pad, so the specification's filter (the last record of each action chain) is seen; the pad calls
`__cxa_call_unexpected` on a negative selector.

### The SSA builder (`scripts/pathb-ssa.rb`)

A block has one state. `(eh-state N)` after an instruction begins a block; a block begins in the state of the first
reached block that jumps to it, so the code after an `if` whose branch returned from inside a cleanup region is in the
state the other path brought. (EDG also writes the enclosing state again at the end of each block, after a `return`.)

The pads' code runs in a terminate state (`(eh-unwind 0)`: a destructor that throws during the unwind calls
`std::terminate`), and the `_Unwind_Resume` call is in a block of its own with the default state (its call site passes the
exception on). Each SSA block says its state with `(eh-unwind B)`.

### Values across the unwind edge

There is no CFG edge from a call to its landing pad (the unwinder makes the transfer, mid-call), so no SSA value and no
phi can travel along it. The function's entry is an empty block whose terminator, `(eh-entry BODY PAD...)`, has the pads
as successors too: for every analysis (the SSA builder's, the e-graph pass's) a pad is dominated only by that empty
block, so no value of the body reaches it and no memory fact flows into it. QBE gets `jmp @BODY`. A promoted slot that is
live into a pad (read on some path from the pad before it is written) stays in memory, as across a `setjmp`.

QBE's own passes must keep the invariant too: its GVN merges equal instructions anywhere and lets GCM place the one
copy, which put a value shared by the body and a pad where both see it (live into the pad, in a register the allocator
assigns without the call's location). In a function with pads GVN merges only into a dominating instruction.

### QBE (`take-cheeze/qbe`, branch `nfcxx/eh-tables`)

- `ehtype ID $sym | ehtype ID 0`, `ehnoexcept`, `ehspec ID...`, `ehpad CLEANUP ID...`, `ehunwind @pad | ehunwind 0`
  (std::terminate).
- The LSDA has one call site per call: its block's pad and the pad's action chain, no pad (the exception passes
  through), or no entry (std::terminate). It has an action table, a type table with `DW.ref` indirections and the
  specification list, as gcc's. A leaf function has no table (nothing unwinds through it).
- Pads are dominated by the entry and reached by no jump; liveness flows from each call into its pad; `simplcfg` keeps
  blocks with different unwind targets apart; a function with pads keeps its frame and its stack slots. Tested on
  x86-64 ELF; the arm64 emitter marks call sites and pads too, untested; rv64 has no tables.

### The EDG fork (`NFCXX_ITANIUM_EH_TYPEINFO`, set with `PATHB_EH=tables`)

EDG's tables describe a pointer by a flag and the pointed-to type's typeinfo (its own runtime's format); libstdc++'s
personality matches a pointer's own `__pointer_type_info`. With the switch, a catch clause of pointer type names the
pointer type's typeinfo, a throw makes the thrown type's own typeinfo (`std::nullptr_t` has none otherwise), and the
destructor a throw passes is the complete-object one (the subobject destructor of a class with virtual bases takes a VTT).

### Runtime (`be/nfcxx_ehrt.c`)

`__nfcxx_personality_v0` calls libstdc++'s `__gxx_personality_v0`. QBE cannot read the registers a personality sets for
a landing pad (gcc's `__builtin_eh_pointer`), so the wrapper keeps the exception and the selector in thread-local
storage when it installs a pad, and the pad reads them first (`__nfcxx_eh_ptr`, `__nfcxx_eh_sel`). The program links
libstdc++ and not `libC.a`: `libC.a` defines its own IA-64 RTTI vtables and `__cxa_vec_*`, which libstdc++'s personality
cannot use. No EH shim either: an exception thrown by libstdc++ is already one of ours.

### The IR passes (`scripts/pathb-ir-opt.rb`)

A callee with landing pads is inlined with them (`eh_inline`): its pads are renumbered after the caller's, its catch
types join the caller's table (the pads compare the selector with `(eh-tid N)`, which the renumbering reaches), and the
copy is bracketed by `(eh-inline-begin K)` and `(eh-inline-end K)`. The callee's state 0 becomes `(eh-state-outer K)`, the
state the copy was entered in; its pads say `(eh-outer K)`, and their resume hands the caller's pad slots the exception
and the selector and becomes `(eh-resume-outer K EXC)`, a jump into the chain of that state's pad (a resume when it is
0, `std::terminate` in a pad's code). The SSA builder resolves these along the control flow, after all the code (a copy
inlined into a pad's code is entered after the pads before it), and appends the outer pad's action chain to the copy's
pads. A `noexcept` callee's copy gets a pad that calls `std::terminate` for its state 0. A callee with a dynamic exception
specification is not inlined. A function without tables inlines as before: its calls get the state of the call site.

## Tests

`tests/pathb-eh-tables/run.sh` (needs a `PATHB_EH=tables` harness and the QBE branch): this mode's probes (region-table
cleanups compared with g++'s output: conditional temporaries, `new` with a throwing constructor, partially built arrays
and objects, a local static whose initializer throws, temporaries of a full expression; exceptions across g++-compiled
code in both directions; `noexcept`), and the EH probes of the frames mode (`tests/pathb-qbe/{cases,traps}/eh_*.cpp`,
`tests/cases/eh_*.cpp`), and inlined callees with pads (two copies in a caller, a copy inside a copy, a catch that
rethrows from a copy, destructors with pads inlined into a pad, a `noexcept` copy). 21 programs, all pass, through the
IR passes, the e-graph pass and QBE's optimizations.

## Known gaps

- A dynamic exception specification of a pointer type is refused (unsupported): EDG makes no typeinfo of the pointer
  type itself for it.
- When an exception leaves a full expression that built argument temporaries, EDG destroys them in construction order,
  not in reverse. The frames mode does the same (it is EDG's region table), so this is no change.
- The driver (`nfcxx`, `scripts/pathb-cc.rb`) does not select the mode or link its runtime yet; `tests/pathb-eh-tables`
  links by hand.
- Targets: tested on x86-64 Linux only (arm64 untested, rv64 and Apple without tables).

## Measured

llama.cpp's `ggml-vulkan.cpp` (`-std=c++17`, the IR passes of `pathb-cc`, the SSA route and QBE), the frames mode against
this one, same scripts and QBE:

| | frames | tables |
|---|---|---|
| instructions (`.text`) | 511,329 | 472,675 |
| `%fs` accesses (EH stack) | 1,281 | 0 |
| `setjmp` calls | 137 | 0 |
| LSDA lines (`.gcc_except_table`) | 0 | 152,543 |

Without the IR passes: 588,395 and 506,324 instructions, 6,045 and 0 `%fs` accesses. Before the pads shared their code
the tables mode had 1,025,661 instructions (each pad repeated its whole chain), and 654,714 before callees with pads
were inlined.

- Mechanism (hand-written QBE, gcc-compiled thrower): a typed catch, a catch-all, a cleanup pad that resumes into a gcc
  `catch`, and `std::terminate` from a `noexcept` function all behave as in gcc.
