# AddressSanitizer for the other backends: plan

Status: the gcc backend is done, and the qbe backend has its first checks (loads and stores, milestone 2 below; `asan.md`,
`tests/asan/run.sh`). This note plans the rest of the qbe backend, Path B and the wasm emitter. Nothing here is implemented; it comes from reading `qbe-prep.rb`, cproc's `qbe.c`,
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

The driver rule of `asan.md` (qbe/Path B refused) is lifted per milestone below, not before the backend passes
`tests/asan/run.sh`. The same cases run on every backend; the report text is the contract, so results are comparable.

## qbe backend (Path A): patch cproc

Done (milestones 1-5): `scripts/cproc-asan.patch`, see `asan.md`. Remaining: 6 below.

Options considered:

| Option | Verdict |
| --- | --- |
| A. Rewrite C text in `scripts/qbe-prep.rb` | Rejected: token-level, no types, cannot tell loads from stores or sizes. |
| B. Patch cproc `qbe.c` (the `3rd/cproc` fork) | **Chosen.** Knows type, size, lvalue, volatile and line. Chokepoints: `funcinst` with `ILOAD*/ISTORE*` from the `qt.load`/`qt.store` tables (~lines 871, 897, 1191-1205, 1521-1524), `funcstore` (832), `funccopy` (806) and blit, `funcalloc` (757), `emitdata` (2001), `emitfunc` (1877), `__builtin_alloca`/VLA. ~500-800 lines of C. |
| C. A QBE pass after `promote`/`ssa` | Fewer redundant checks and also covers Path B output, but loses C types, volatile and line info, and needs blit expansion and abi0 handling. Revisit for check elimination. |

Milestones:
1. cproc flag `-fsanitize=address`; `scripts/qbe-cc` passes it and links with `-fsanitize=address`.
2. Checks before every load, store and `funccopy`/blit; skip `va_arg`/`reg_save_area` and `__nfcxx_*` helpers. Tests: heap overflow, use after free, double free.
3. Stack redzones (done, `asanalloc`): `funcalloc` allocates `size + 2*RZ` (RZ 32), poisons at the declaration, unpoisons in `funcret`. Dynamic allocations (done, `asandynalloc` / `asandynret`): `alloca` and C-input VLAs, see `asan.md`. Open: C++ VLAs (EDG's `__vla_alloc` runtime, no redzone between VLAs; needs the EDG lowering or runtime, not cproc).
4. Global redzones (done, `emitdata` and `emitasanctor`): a trailing redzone in each global's own data item, poisoned by a per-unit constructor in `.init_array`. No leading redzone.
5. Source lines (done): `qbe-cc` keeps the line markers under `NFCXX_ASAN`, cproc emits `dbgloc` and `dbgfile`.
6. Optional: use after scope, fake stack (use after return), elision of checks on non-escaping locals.
Open check: the unwinder wants `rbp` chains; QBE keeps them, but verify with a report.

## Path B: emit from `pathb-qbe-emit.rb`

All accesses are explicit IR (`load`, `store`, `bfload`/`bfstore`, `copy`, `zero-fill`); the emitter chokepoints are
`r_load` (~1455), `s_store` (~1640), `r_bfload`/`s_bfstore` (~1704/1746), `s_copy` (1849, `memmove`), `s_zero_fill`
(1858, `memset`). `Fn#trap_if` (837) shows the check shape. `memmove`/`memset` and `malloc` are covered by libasan's
interposers. Volatile accesses (`vhelper`, 1445) are the existing "access becomes a call" example.

Milestones:
1. `NFCXX_PATHB_ASAN=1`: emit `__asan_load/storeN` before `r_load`, `s_store`, bit-field and copy/zero-fill; link libasan. Tests: heap overflow, use after free.
2. Slot redzones: enlarge each address-taken slot to `[rz | obj | rz]` (as the over-aligned slot code ~2529 does), poison in `@start`, unpoison before every `ret` and the `@abort` block. Non-address-taken slots stay promotable and need none.
3. Global redzones in `emit_global` (2426) with `__asan_register_globals` from a constructor.
4. setjmp/longjmp EH (EDG's ABI; libasan's longjmp interceptor unpoisons the stack), VLA (EDG lowers to `__vla_alloc` pool calls, seen as malloc blocks) and alloca. Test: copy of `tests/asan/cases/clean.cpp`.
5. Driver and tests: a `// ASAN-EXPECT:` runner next to `traps/` in `tests/pathb-qbe/`, compared with the gcc report.
6. Use after scope needs `(scope-begin/end $slot)` IR forms from `ir.c`.
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
