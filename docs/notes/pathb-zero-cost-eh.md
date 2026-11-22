# Path B: zero-cost exception handling

Status: the default (`scripts/setup-pathb.sh`, `PATHB_EH=tables`). `PATHB_EH=frames` builds a harness with EDG's portable
EH lowering instead (an EH stack of runtime frames in thread-local storage, `setjmp`/`longjmp` for `try`, EDG's runtime in
`libC.a`). A harness says which it is: `cmake/bin/eh-tables` exists beside its cpfe in the tables mode.

## Where it goes

| consumer | exception tables |
|---|---|
| the SSA route (`scripts/pathb-ssa-build`, QBE) | landing pads and the LSDA (below) |
| the mruby emitter (`scripts/pathb-qbe-emit.rb`, `--emitter=mruby`) | the same QBE directives, with the SSA route's state rules |
| CIL (`scripts/pathb-cil-emit.rb`) | the body in one protected block, the pads after it (its `eh_try`); see `docs/notes/pathb-cil.md` |
| wasm, SPIR-V, WGSL, HVX | the pads and states are dropped (nothing unwinds there); a throw is refused where it is |
| PTX, AMDGPU | CUDA device code is compiled with `--no_exceptions`: no tables |
| QBE's i386 target | refused (it writes no tables and no CFI) |

The link: `scripts/pathb-ldrt.rb` prints a GNU ld input script in place of `libnfcxxld.a` when the harness has tables,
`INPUT(libnfcxxld.a libnfcxxedg.a -lstdc++ -lgcc_s)`, so every Path B link line (which names `libC.a` after it) gets the
lowering's helpers and libstdc++'s C++ ABI, EH runtime, RTTI and `operator new` first, and takes nothing from `libC.a`.
`libnfcxxedg.a` is `libC.a`'s three self-contained members the lowering calls (`vla_alloc.o`, `c99_complex.o` and the
abort message of `error.o`), copied out by the script, so a link that does not name `libC.a` at all
(`g++ x.o $(scripts/pathb-ldrt.rb)`) has everything. The driver and
`tests/pathb-qbe/run.sh` link no EH shim then (the shim hands libstdc++'s throws to EDG's runtime).

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
  chain) and whether it also cleans up. Its code begins with `(eh-exc)` and `(eh-sel)`, the exception and the selector
  the personality installed (QBE's `ehptr`, `ehsel`), and ends in a jump to a handler's label, `std::terminate`, or
  `(eh-resume EXC)`.

`throw()` and `noexcept` are both `(eh-noexcept)`: a call with no pad has no call-site entry, so an exception that
reaches it calls `std::terminate`, and a pad of such a function cleans up and then calls it. With `(eh-spec ...)`
every state has a pad, so the specification's filter (the last record of each action chain) is seen; the pad calls
`__cxa_call_unexpected` on a negative selector, in the default state: an exception the unexpected handler throws that
the specification allows leaves the function from that call (`tests/pathb-eh-tables/cases/spec_unexpected_rethrow.cpp`).

A full expression's temporaries (each a region with a flag) are chained in the order EDG builds them, under one region
set before the expression; the pad destroys such a run of conditional regions backwards, so an exception destroys them
in the reverse order of their construction, as [except.ctor] says
(`tests/pathb-eh-tables/cases/arg_temporaries_order.cpp`).

An exception object built in place from subobjects (`throw E{S(...), g()}`) has regions whose handle is only the
member's offset in that object (no variable). A throw in such a function keeps the object's address in a slot
(`eh.thrown`), and the pad destroys the members built so far through it; `__cxa_throw` is called outside those
regions, as the object is complete then (`tests/pathb-eh-tables/cases/throw_subobjects.cpp`). A throw whose operand makes a call runs
it in a frame of its own, whose pad frees the object (`__cxa_free_exception`, as gcc) after the cleanups of the members
it built; `__cxa_throw` is outside it (`tests/asan/cases/clean_throw_ctor_free.cpp`, with LeakSanitizer). An operand
that makes no call (`throw 42`) gets neither the frame nor the slot.

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
  (std::terminate), `ehnothrow $sym...` (callees that let no exception out).
- A call site of the LSDA has its block's pad and the pad's action chain, no pad (the exception passes through), or no
  entry (std::terminate). As gcc's, one site covers consecutive calls with the same pad when no call without an entry
  comes between them, and a call of an `ehnothrow` callee has no entry and sits inside any range. It has an action table, a type table with `DW.ref` indirections and the
  specification list, as gcc's. A leaf function has no table (nothing unwinds through it).
- `%e =l ehptr`, `%s =l ehsel`: in a pad, the exception and the selector the personality installed (gcc's
  `__builtin_eh_pointer` and `__builtin_eh_filter`). The abi passes move them to the top of the pad and make them copies
  of `%rax` and `%rdx` (`x0`, `x1` on arm64). The personality is libstdc++'s `__gxx_personality_v0` itself.
- Pads are dominated by the entry and reached by no jump; liveness flows from each call into its pad (its temporaries,
  not the two registers); the spiller loads a pad's live-in temporaries from their slots at its entry (after the two
  copies: no register but those survives the unwind), and a block without successors whose calls unwind to a pad keeps
  no register for them; `simplcfg` keeps blocks with different unwind targets apart; a function with pads keeps its
  frame and its stack slots; a call that unwinds to a pad or to std::terminate is never a tail call. Tested on x86-64
  ELF; the arm64 emitter marks call sites and pads too (CI's arm64 Linux job runs it); rv64 has no tables.

### Nothrow callees (`scripts/pathb-ssa-qbe.rb` `nothrow_callees`)

The emitter lists with `ehnothrow` the direct callees of a function with tables that let no exception out: a `noexcept`
function of the module (an exception that would leave it calls std::terminate); a function of the module whose
definition every call reaches (static, an inline or template instance, or exported outside a shared object: not
`__attribute__((weak))`, not preemptible with `-fPIC`), with no dynamic exception specification, whose calls are all
direct calls of such functions; and libc's nothrow routines (`scripts/pathb-nothrow.rb`; not stdio's output routines,
which are cancellation points). A declaration's `noexcept` is not in the IR, so a callee the module does not define is
nothrow only when it is in that list. On `lib/ast/nfcast_parse.cpp` (-O2) the merged ranges and the nothrow callees take
`.gcc_except_table` from 12,164 bytes to 4,728 (g++ -O2: 3,143).

### The EDG fork (`NFCXX_ITANIUM_EH_TYPEINFO`, set with `PATHB_EH=tables`)

EDG's tables describe a pointer by a flag and the pointed-to type's typeinfo (its own runtime's format); libstdc++'s
personality matches a pointer's own `__pointer_type_info`. With the switch, a catch clause of pointer type names the
pointer type's typeinfo, a throw makes the thrown type's own typeinfo (`std::nullptr_t` has none otherwise), and the
destructor a throw passes is the complete-object one (the subobject destructor of a class with virtual bases takes a VTT).

### Runtime

None of Path B's own: a pad reads the exception and the selector with `(eh-exc)` and `(eh-sel)` (QBE's `ehptr`, `ehsel`),
the personality is libstdc++'s `__gxx_personality_v0`, so an object with tables needs only libstdc++ (`g++ x.o` links
it). The program links libstdc++ first and `libC.a` after it (`scripts/pathb-ldrt.rb`'s link script): `libC.a` defines its own IA-64 RTTI vtables, `__cxa_*` and `__cxa_vec_*`, which libstdc++'s
personality cannot use, so libstdc++ must provide those; the lowering's helpers (the VLA pool, C99 complex arithmetic:
self-contained members) come from `libnfcxxedg.a`, ahead of `libC.a`. No EH shim either: an exception thrown by
libstdc++ is already one of ours.

### The IR passes (`scripts/pathb-ir-opt.rb`)

A callee with landing pads is inlined with them (`eh_inline`): its pads are renumbered after the caller's, its catch
types join the caller's table (the pads compare the selector with `(eh-tid N)`, which the renumbering reaches), and the
copy is bracketed by `(eh-inline-begin K)` and `(eh-inline-end K)`. The callee's state 0 becomes `(eh-state-outer K)`, the
state the copy was entered in; its pads say `(eh-outer K)`, and their resume becomes `(eh-resume-outer K EXC SEL)`: the
exception and the selector go to the slots the stub of that state's pad stores to, then a jump into its chain (a resume
when it is 0, `std::terminate` in a pad's code). That pad may be another copy's (a callee inlined into an inlined
body), whose slots are that copy's, not the function's (`tests/pathb-eh-tables/cases/inline_nested_resume.cpp`). The SSA builder resolves these along the control flow, after all the code (a copy
inlined into a pad's code is entered after the pads before it), and appends the outer pad's action chain to the copy's
pads. A `noexcept` callee's copy gets a pad that calls `std::terminate` for its state 0. A callee with a dynamic exception
specification is not inlined. A function without tables inlines as before: its calls get the state of the call site.

## Tests

`tests/pathb-eh-tables/run.sh` (needs a `PATHB_EH=tables` harness and the QBE branch): this mode's probes (region-table
cleanups compared with g++'s output: conditional temporaries, `new` with a throwing constructor, partially built arrays
and objects, a local static whose initializer throws, temporaries of a full expression; exceptions across g++-compiled
code in both directions; `noexcept`; the forced unwind of `pthread_exit` and `pthread_cancel` and a foreign
exception, through pads and `catch (...)`; the nothrow callees), and the EH probes of the frames mode (`tests/pathb-qbe/{cases,traps}/eh_*.cpp`,
`tests/cases/eh_*.cpp`; with `--all`, every program of `tests/pathb-qbe/cases` and `tests/cases`: 200, all pass), and
inlined callees with pads (two copies in a caller, a copy inside a copy, a catch that
rethrows from a copy, destructors with pads inlined into a pad, a `noexcept` copy). 21 programs, all pass, through the
IR passes, the e-graph pass and QBE's optimizations.

## Known gaps

- A dynamic exception specification of a pointer type is refused (unsupported) when nothing else in the unit makes the
  pointer type's typeinfo (a `catch` of it does): EDG makes none for the specification alone.
- The frames mode destroys a full expression's temporaries in construction order when an exception leaves it (EDG's
  runtime walks the region chain as it is); the pads run such a run backwards (below).
- Targets: tested on x86-64 Linux; QBE's arm64 emitter marks call sites and pads too (CI's arm64 Linux job runs it).
  A macOS host builds a frames harness by default: ld64 reads no linker script, so `scripts/pathb-ldrt.rb` cannot put
  libc++abi ahead of the `libC.a` the links name (its C++ ABI members would win), and QBE's Mach-O tables are untested.
  QBE's rv64 writes no tables, its i386 neither (refused).
- CIL: exact catch types only, see `docs/notes/pathb-cil.md`.

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
