# Path B: zero-cost exception handling

Status: the default (`scripts/setup-pathb.sh`, `PATHB_EH=tables`). `PATHB_EH=frames` builds a harness with EDG's portable
EH lowering instead (an EH stack of runtime frames in thread-local storage, `setjmp`/`longjmp` for `try`, EDG's runtime in
`libC.a`). A harness says which it is: `cmake/bin/eh-tables` exists beside its cpfe in the tables mode.

The tests' expectations are a tables harness's output. With a frames harness, `tests/pathb-ir/run.sh` reports the
goldens it differs from as skipped (and refuses `--update`), `tests/pathb-borrow/run.sh` compares the destructor tests'
slot names without the frames mode's numbering (`tmp.2` for `tmp`), and `tests/pathb-eh-tables/run.sh` refuses to run.

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
  (std::terminate), `ehnothrow $sym...` (callees that let no exception out), `ehspecpad @pad K ID...` (list K of a landing
  pad's own specifications; a negative `ehpad` entry -K is that list's filter, at its place in the chain; the lists follow the
  function's after `.LEHTT`, and a filter is `.LEHTT - list - 1`, so a list is found at its offset as gcc's do; a pad without
  lists ends its chain with the function's `ehspec` filter).
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
- Cold code (`ehcoldmark`, ELF only, `3rd/qbe` commit 159392a): a function with landing pads emits the blocks that only
  its pads reach (cleanups, catch clauses, the pads themselves) after the hot code, in `.text.unlikely`, with an FDE and an
  LSDA of their own. A hot call's pad is cold code too, so the hot LSDA has LPStart at the start of the cold part. No
  nfcxx change is needed to get it: QBE marks the blocks itself. Measured: `f_try` in `tests/pathb-eh-tables/cases/cold_pads.cpp`
  391 to 173 bytes of hot code, `main` of `bench.cpp` 1536 to 837; hot plus cold code is about the same size (3415 to 3402).

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
specification is inlined only when `spec_inlinable?` (scripts/pathb-ir-opt.rb) holds: every exception that can leave it is
one of its types, so its filter never fails and the copy needs none. (Below: the copy with its own filter.) Every call of the body must be `__cxa_throw` of a
type of the specification (the exact typeinfo), `__cxa_allocate_exception`, a function of the module that cannot let an
exception out (`throwing_functions`), or a nothrow libc routine; its pads may only call `__cxa_free_exception` and
`__cxa_call_unexpected` (so no destructor of a live object runs on the way out, which the copy would skip). The copy drops
the pads, the specification and the state markers: its throws are the caller's, as for a function without tables (its
calls get the state of the call site). `tests/pathb-eh-tables/cases/inline_spec.cpp` checks it against g++ (a callee that
throws another type, or has a destructor, stays a call: std::unexpected runs). A function without tables inlines as
before: its calls get the state of the call site.

A callee whose filter is needed in the copy (`spec_inlinable?` fails: a throw of another type, a call of a function
that can throw, a rethrow, a destructor on the way out) is still inlined (`spec_copyable?`, scripts/pathb-ir-opt.rb) when
the caller has no specification of its own (`eh[:filtered]`: a function-level `eh-spec`, whose filter is not in the chains
of the copy's pads). A call of a module function in the callee stays a call in the copy,
or is inlined into it later: either way the copy's pads filter what it lets out. The copy keeps its pads, and each carries the callee's list as
an `(eh-spec-pad PAD ID...)` form, which the SSA builder writes as `ehspecpad` (QBE): the pad's action chain is its own
clauses, then that filter (a mismatch calls `__cxa_call_unexpected` in the personality), then the clauses of the state the
copy was entered in and that state's own filters, then its cleanup. An action record of a filter is `-K` in the pad's `ehpad`
list, its list is `ehspecpad @pad K ID...` (QBE), so a pad can have one per copy it is nested in, in order. A non-spec copy inside
such a copy takes the copy's list (`eh[:own]`). `tests/pathb-eh-tables/cases/inline_spec_filter.cpp` checks it against g++.
`tests/pathb-eh-tables/cases/inline_spec_module_call.cpp` checks a callee that calls a variadic module function (never inlined)
and one that calls a small one (inlined into the copy later), against g++.
A copy under a caller's `try` or clauses is inlined too: the copy's filter comes before them in the chain, so an exception
the callee does not allow goes to std::unexpected and not to a caller's handler (`inline_spec_caught.cpp`). A copy inside a copy
with a list of its own has both filters on its chain, in order (`inline_spec_nested.cpp`). A noexcept callee whose copies carry
lists is inlined: its terminate pad comes after them (`inline_noexcept_spec*.cpp`, `traps/inline_noexcept_spec_*.cpp`).
A caller with a function-level dynamic specification (`ehspec`) takes such copies too. The caller's filter is the last
record of every copy's chain: QBE appends it to a pad without lists, and `scripts/pathb-ssa.rb` (`fn_spec_tail`) appends it
to a copy's pad with lists (QBE's ehspecpad: a pad with lists gets no ehspec of its own). A copy's pad whose outer state is
a terminate state (a noexcept copy's, or a pad's own code) ends in catch (...) instead, so the caller's filter is not
checked for an exception that leaves a noexcept copy: it calls std::terminate. A noexcept copy's terminate pad always has
the catch (...) clause. `inline_spec_caller_list.cpp`, `inline_spec_caller_list_rev.cpp`, `inline_spec_caller_nested.cpp`,
`inline_spec_caller_plain.cpp` and the traps `inline_noexcept_caller_spec.cpp`, `inline_spec_callee_unexpected.cpp` check it
against g++.
Known difference (not refused): with a copy of a callee that has its own list and a destructor, the callee's own list is
checked before the cleanups of an enclosing copy's body run when the exception enters that body through a copy's resume
(g++ runs them first: destructor output of a doubly nested copy, `inline_spec_caller_nested.cpp` keeps its destructor in the
inner copy only, where the order matches). The handler that runs and what it throws are the same.

## Tests

`tests/pathb-eh-tables/run.sh` (needs a `PATHB_EH=tables` harness and the QBE branch): this mode's probes (region-table
cleanups compared with g++'s output: conditional temporaries, `new` with a throwing constructor, partially built arrays
and objects, a local static whose initializer throws, temporaries of a full expression; exceptions across g++-compiled
code in both directions; `noexcept`; the forced unwind of `pthread_exit` and `pthread_cancel` and a foreign
exception, through pads and `catch (...)`; the nothrow callees), and the EH probes of the frames mode (`tests/pathb-qbe/{cases,traps}/eh_*.cpp`,
`tests/cases/eh_*.cpp`; with `--all`, every program of `tests/pathb-qbe/cases` and `tests/cases`: 201, all pass), and
inlined callees with pads (two copies in a caller, a copy inside a copy, a catch that
rethrows from a copy, destructors with pads inlined into a pad, a `noexcept` copy). 21 programs, all pass, through the
IR passes, the e-graph pass and QBE's optimizations.

## Known gaps

- A dynamic exception specification of a pointer to member or of `std::nullptr_t` is refused (unsupported): EDG's
  description of those types is not the IA-64 typeinfo. The EDG fork makes the typeinfo of every other type of a
  specification (`tests/pathb-eh-tables/cases/spec_pointer_types.cpp`).
- The frames mode destroys a full expression's temporaries in construction order when an exception leaves it (EDG's
  runtime walks the region chain as it is); the pads run such a run backwards (below). It also destroys the members of
  an exception object built in place (`throw E{S(...), ...}`) twice when the throw succeeds: their regions are still
  current when EDG's runtime starts the unwind. The gcc back end has the same two (it uses EDG's runtime too).
- Targets: tested on x86-64 Linux; QBE's arm64 emitter marks call sites and pads too (CI's arm64 Linux job runs it).
  macOS arm64: see "macOS arm64" below. QBE's rv64 writes no tables, its amd64 Apple target refuses them, and its i386
  neither (refused).
- CIL: catch clauses match exact types, public unambiguous non-virtual bases and pointers to them (not virtual bases,
  not libstdc++ base classes); a throw from a pad's own code does not call std::terminate; dynamic exception
  specifications are refused. See `docs/notes/pathb-cil.md`, "Catch matching".
- Debug info: `-g` gives a line table only (`.debug_line`: gdb has the source line of each frame and steps by line, the
  pads too); there is no variable or type information (`.debug_info` describes the compile unit only).

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

## macOS arm64

The harness on a macOS host is a tables harness too (`scripts/setup-pathb.sh` defaults to `PATHB_EH=tables` everywhere).
`tests/pathb-eh-tables/run.sh` passes on arm64 macOS (29 of 29, with the cases of tests/pathb-qbe and tests/cases). The
tables are Mach-O, and what that takes:

- **CFI everywhere** (`arm64/emit.c`): Apple arm64 writes `.cfi_*` for each non-leaf function too, not only for those with
  tables: a throw unwinds through callers that have none. QBE's amd64 Apple target still writes none (it refuses tables).
- **The personality and the LSDA** (`emit.c`, `ehfnbegin`): `.cfi_personality 0x9b, ___gxx_personality_v0` names the
  symbol (the assembler makes its GOT entry, as clang's output). The LSDA pointer is `.cfi_lsda 16` (aligned absolute, as
  clang), not `0x1b`: with pcrel the assembler writes a `__LD,__compact_unwind` entry of 84 bytes, and ld64 rejects it.
- **A non-local symbol at each LSDA** (`ehtabend`): `GCC_except_tableN:` before the table, as clang's. Without it the
  assembler resolves the LSDA pointer of a function that follows another with a table into the previous table (24 bytes
  early), and the throw is not caught. Local `L` names alone do not do it. The bug showed as "terminating due to uncaught
  exception" in a `main` that caught the exception, whenever a function with a cleanup came first in the object.
- **Types through the GOT**: each type id is `sym@GOT - label` (`.LEHTY`), as clang's, not an ELF `DW.ref` indirection.
- **Labels**: the EH labels are `asloc`-prefixed (`L` on Mach-O, where only `L` names are assembler-local; `.L` on ELF).
  The ELF output is byte-identical to the previous QBE (checked on 23 programs, both `arm64` and `amd64_sysv`).
- **Asm labels of the C library** (`be/nfcxx_ir.c`, `ir_asm_label_sym`): Apple's `__DARWIN_ALIAS(f)` is `__asm("_" f)`, and
  the IR names a symbol by its label. On a Darwin host the label's underscore is taken off, since the emitter adds one
  back: the IR had `_fwrite`, which became `__fwrite`.
- **Atomics** (`be/nfcxx_ldrt.c`, Darwin only): the lowering calls the GNU libatomic names (`__atomic_fetch_add_8`, ...).
  Darwin's compiler-rt has only the outline helpers, so the sizes 1, 2, 4 and 8 are defined in the runtime archive, with
  builtins that compile inline. 16 bytes is not provided.
- **The link** (`scripts/pathb-ldrt.rb`, `tests/pathb-eh-tables/run.sh`): ld64 reads no linker script, so on a Mach-O host
  `pathb-ldrt.rb` prints one archive (`libnfcxxld-eh.a`: the long double member and the three EDG helper members of
  `libC.a`), and the links name `-lc++` in place of `-lstdc++ -lgcc_s -latomic`. `libC.a`'s EH runtime is not linked.
- **Messages**: `tests/cases/eh_libstdcxx_throw.cpp` checks libstdc++'s `what()` texts only under `__GLIBCXX__`; the type
  checks run on either library.

Not done: the `nfcxx` driver's Path B port (`scripts/nfcxx-pathb.rb`) still refuses any host but x86-64 Linux, and the
default backend on macOS is still gcc. So hosted programs built by `nfcxx` on a Mac do not use this route yet. The
freestanding and Path B hosted link lines on macOS (`scripts/nfcxx-pathb.rb`, `c_only_link`) name `-lstdc++` too.
