# AddressSanitizer for the other backends: plan

Status: the gcc backend is done, the qbe backend has milestones 1-7 below (loads and stores, redzones, use after scope,
use after return; `asan.md`, `tests/asan/run.sh`), and Path B has its milestones 1 to 4 and 6 (heap checks, stack, global and alloca redzones, use after scope: `NFCXX_PATHB_ASAN`, `asan.md` "Path B").
This note plans the rest of Path B and the wasm emitter. Nothing of wasm is implemented; the qbe part is, and its notes say what is done. The plan was written from reading `qbe-prep.rb`, cproc's `qbe.c`,
QBE, `be/nfcxx_ir.c` and `scripts/pathb-qbe-emit.rb`, and nothing was run. Line numbers are approximate.

## Common design

Reuse the host's libasan for the runtime (shadow memory, malloc/free interception, quarantine, leak check, report text),
and emit only the checks ourselves: `call $__asan_load{1,2,4,8,16}(l addr)`, `__asan_store{N}`, and
`__asan_loadN/storeN(addr, size)` for other sizes, before the access. Link with `gcc -fsanitize=address` so the runtime
starts through its preinit array; the instrumentation passes of gcc are not needed. Stack and global redzones use
`__asan_poison_memory_region` / `__asan_unpoison_memory_region` and `__asan_register_globals`. The descriptor ABI of
the latter is libasan-version specific, so it is pinned to the host gcc (CI: gcc 13). A check is a call placed before the
access, which also keeps QBE from merging or forwarding the load (the reason volatile accesses are helper calls).
Known limit for all: EDG's `libC.a` is not instrumented; heap errors are still found through `malloc` interposition.

The driver rule of `asan.md` (Path B refused) is lifted per milestone below, not before the backend passes
`tests/asan/run.sh`. The same cases run on every backend; the report text is the contract, so results are comparable.

## qbe backend (Path A): patch cproc

Done (milestones 1-7). The cproc changes are on the `nfcxx-asan-combined` branch of take-cheeze/cproc, and `3rd/cproc` is
pinned to its commit a44a644. See `asan.md`. Open: elision of checks (optional, below).

Options considered:

| Option | Verdict |
| --- | --- |
| A. Rewrite C text in `scripts/qbe-prep.rb` | Rejected: token-level, no types, cannot tell loads from stores or sizes. |
| B. Patch cproc `qbe.c` (the `3rd/cproc` fork) | **Chosen.** Knows type, size, lvalue, volatile and line. Chokepoints: `funcinst` with `ILOAD*/ISTORE*` from the `qt.load`/`qt.store` tables (~lines 871, 897, 1191-1205, 1521-1524), `funcstore` (832), `funccopy` (806) and blit, `funcalloc` (757), `emitdata` (2001), `emitfunc` (1877), `__builtin_alloca`/VLA. ~500-800 lines of C. |
| C. A QBE pass after `promote`/`ssa` | Fewer redundant checks and also covers Path B output, but loses C types, volatile and line info, and needs blit expansion and abi0 handling. Revisit for check elimination. |

Milestones:
1. Done: `NFCXX_ASAN=1` selects the instrumentation; `scripts/qbe-cc` links with `-fsanitize=address` under it.
2. Done (`funcinst`): a check before every load and store, the chunks of a block copy (`funccopy`) included. No exemptions
   were needed: the `va_arg` save area is ordinary stack memory, and the scalar `IVAARG` instruction is not checked. Tests:
   heap overflow, use after free, double free.
3. Stack redzones (done, `asanalloc`): `funcalloc` allocates `size + 2*RZ` (RZ 32), poisons at the declaration, unpoisons in `funcret`. alloca, C-input VLA and over-aligned objects too (`asandynalloc` and the over-aligned branch of `asanalloc`).
4. Global redzones (done, `emitdata` and `emitasanctor`): a trailing redzone in each global's own data item, poisoned by a per-unit constructor in `.init_array`. No leading redzone.
5. Source lines (done): `qbe-cc` keeps the line markers under `NFCXX_ASAN`, cproc emits `dbgloc` and `dbgfile`.
6. Use after scope (done, `asanend`/`asanleave`/`asangoto`/`asanlabel`/`asancase`, `asan.md` "Use after scope"): a block's
   objects are poisoned with `__asan_poison_stack_memory` when the block is left (normal end, break, continue, goto, and
   the jumps EDG lowers from C++ break, continue and switch) and unpoisoned by their declaration or by a jump into the
   block. Return needs nothing (funcret). A setjmp call (`setjmp`, `_setjmp`, `sigsetjmp`, `__sigsetjmp`) poisons, at its return,
   every object whose block is not open at the call (`asansetjmp`, `asanfinish`): that covers a C longjmp and EDG's throw to a
   `try` in the same frame, with no record of the longjmp. Tests: `scope_throw_escape.cpp`, `scope_longjmp_escape.c` (qbe
   only) and their clean cases. Not done: a setjmp under another name, and an exit that leaves a callee's frame (the callee's
   objects). Still open, optional: elision of checks on non-escaping locals.
7. Use after return (done, `asanalloc`, `asanselect`, `asanfree`, `asan.md` "Use after return"): every fixed-size object of
   align 16 or less is in a libasan fake frame (`__asan_stack_malloc_N` at the entry, `__asan_stack_free_N` at each return),
   with gcc's ABI and header, so the report is `stack-use-after-return` on both backends. Not done: one frame per function
   (gcc's), objects over 16-byte alignment, VLA and alloca (the real frame only).
Open check: the unwinder wants `rbp` chains; QBE keeps them, but verify with a report.

## Path B: emit from the SSA route (`pathb-ssa-qbe.rb`)

The default emitter is the SSA route, not `pathb-qbe-emit.rb` (the mruby emitter named below, which `NFCXX_PATHB_EMITTER=mruby`
selects and which has no ASan support). Milestone 1 is in `pathb-ssa-qbe.rb`: `Qbe.asan`, set by `--asan`, and `asan_check`, called
beside each `safe_check`. The names below are the mruby emitter's; the SSA route's are `load`/`store`/`copy`/`zero-fill`/`bfload`/
`bfstore` and their volatile forms in `item_lines` (statements) and `let_lines` (loads).

All accesses are explicit IR (`load`, `store`, `bfload`/`bfstore`, `copy`, `zero-fill`); the emitter chokepoints are
`r_load` (~1455), `s_store` (~1640), `r_bfload`/`s_bfstore` (~1704/1746), `s_copy` (1849, `memmove`), `s_zero_fill`
(1858, `memset`). `Fn#trap_if` (837) shows the check shape. `memmove`/`memset` and `malloc` are covered by libasan's
interposers. Volatile accesses (`vhelper`, 1445) are the existing "access becomes a call" example.

Milestones:
1. Done: `NFCXX_PATHB_ASAN=1`: `__asan_load/storeN` before each load, store, bit-field, copy and zero-fill; the link adds libasan and the VLA
   runtime. Tests: `ASAN_BACKEND=pathb tests/asan/run.sh` (heap overflow, use after free, double free, mismatch, leak, vector, VLA
   overflow; the rest is listed in `tests/asan/pathb-pending.txt`). A VLA's `(bounds ...)` trap is dropped under the flag so libasan
   reports it; a constant bound still traps until M2 and M3.
2. Done: slot redzones. Each slot that stays in memory (`allocs` in the SSA route) becomes `[32 | obj | 32]` (`asan_slot`), poisoned at the entry (`asan_poison`)
   and unpoisoned before the `ret` (`asan_leave`); the trap blocks end in `hlt`, which needs no unpoison. Promoted slots need none. The report is
   `use-after-poison`, as on qbe (`// ASAN-PATHB:` in the cases).
3. Done: global redzones in the SSA route's `build_data` and `string_data`, poisoned by `asan_constructor` (`__asan_poison_memory_region`, as qbe does, not
   `__asan_register_globals`, whose descriptor ABI is libasan-version specific). `(bounds ...)` traps are dropped under the flag.
4. Done: alloca (`[32 | obj | 32]` blocks chained per frame and released before the `ret`, `lib/asan/nfcxx_vla_asan.c`), VLA (the ASan runtime makes each a malloc
   block) and setjmp/longjmp EH (libasan's longjmp interceptor unpoisons the dead frame; `clean_throw_reuse.cpp`, `scope_*_clean`). Test: `clean_alloca_reuse.cpp`. For the scope of a same-frame exit, the qbe design (poison at the setjmp return, the objects whose block is not open at the call) carries over if Path B's blocks are known at the call.
5. Done: the driver and the runner are `tests/asan/run.sh` with `ASAN_BACKEND=pathb` (a CI entry in `pathb-test`), and the report has source lines:
   `NFCXX_IR_LOC=1` under the flag, QBE `dbgfile` per function and `dbgloc` per `(loc ...)` (`asan_dbgloc`, `function_text`).
6. Done (except compound literals): the IR forms are the borrow facts `(decl $"x" val)` and `(scope-end $"x")`, printed alone under `NFCXX_IR_SCOPES=1`
   (`be/nfcxx_ir.c`), poisoned and unpoisoned with `__asan_poison_stack_memory` / `__asan_unpoison_stack_memory` (`asan_scope`). A compiler temporary
   (a compound literal) has no fact: `scope_compound_escape.cpp` is pending.
7. Optional: redundant-check elimination within a block, own runtime.
Risks: slots passed to `__asan_*` escape and lose QBE promotion (slower code); bit-fields access whole units; libasan ABI version.

## wasm emitter

No libasan on wasm, so this needs an own runtime: a shadow region (1/8) carved from linear memory at module build
time, inline shadow checks or an in-module check function before each op (`store` via `addr32`/`store_op` ~1170,
`memory.copy` ~1181), a `malloc` with redzones and a quarantine, and `unreachable` as the report. Slots are on a
shadow stack in linear memory (global 0 is the stack pointer) and globals are at fixed addresses, so redzones are plain
offsets. Do this last, after the Path B shape is settled.

## Order and effort

Recommended order: qbe (cproc) first, since it is the default backend, then Path B; the two share the runtime and
tests, and can proceed in parallel after milestone 2 of each. Rough effort from the readings: qbe 1-2 weeks,
Path B 1-2 weeks for milestones 1-4 and 3-4 weeks with scope tracking and wasm.
