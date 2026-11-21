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
- `throw` is `__cxa_allocate_exception`, the lowered copy into it, `__cxa_throw` (typeinfo, destructor); `throw;` is
  `__cxa_rethrow`. A handler is `__cxa_begin_catch` on entry and `__cxa_end_catch` at the catch epilogue.
- The pad keeps the exception and the selector in two stack slots (`eh.exc`, `eh.sel`), which the handlers read.

### IR forms

- `(eh-types SYM-or-0 ...)`, `(eh-noexcept)`: function header; the catch clauses' typeinfo symbols (type ids from 1).
- `(eh-state N)`: statement.
- `(eh-pad N CLEANUP (TID ...) STMT ...)`: function level, after the body; the pad's catch clauses' type ids (the action
  chain) and whether it also cleans up.
- `(eh-resume)`: statement in pad code.

The SSA builder (`scripts/pathb-ssa.rb`) splits blocks at `(eh-state N)`: each block knows its pad. The state of a
branch starts as the state at the `if`; after the join it is the state at the end of the branch that falls through. A
conditional temporary's region tests its flag, so the state after a `?:` that constructed one on a single path is safe.

### Values across the unwind edge

There is no CFG edge from a call to its landing pad (the unwinder makes the transfer, mid-call), so no SSA value and no
phi can travel along it. Pads and the code they reach read only stack slots and values they compute themselves; the
builder keeps those slots in memory, and QBE does not promote or share the slots of a function with pads.

### QBE (`take-cheeze/qbe`, branch `nfcxx/eh-tables`)

- `ehtype ID $sym | ehtype ID 0`, `ehnoexcept`, `ehpad CLEANUP ID...`, `ehunwind @pad | ehunwind 0` (std::terminate).
- The LSDA has one call site per call: its block's pad and the pad's action chain, no pad (the exception passes
  through), or no entry (std::terminate). It has an action table and a type table with `DW.ref` indirections, as gcc's.
- Pads are dominated by the entry and reached by no jump; liveness flows from each call into its pad; `simplcfg` keeps
  blocks with different unwind targets apart; a function with pads keeps its frame and its stack slots.

### Runtime (`be/nfcxx_ehrt.c`)

`__nfcxx_personality_v0` calls libstdc++'s `__gxx_personality_v0`. QBE cannot read the registers a personality sets for
a landing pad (gcc's `__builtin_eh_pointer`), so the wrapper keeps the exception and the selector in thread-local
storage when it installs a pad, and the pad reads them first (`__nfcxx_eh_ptr`, `__nfcxx_eh_sel`). The program links
libstdc++ and not `libC.a`: `libC.a` defines its own IA-64 RTTI vtables and `__cxa_vec_*`, which libstdc++'s personality
cannot use.

## Measured so far

- Mechanism (hand-written QBE, gcc-compiled thrower): a typed catch, a catch-all, a cleanup pad that resumes into a gcc
  `catch`, and `std::terminate` from a `noexcept` function all behave as in gcc.
