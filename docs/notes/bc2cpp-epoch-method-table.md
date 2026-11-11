# Does an epoch-validated method table pay? (bc2cpp owner calls)

Status: measured 2026-11-09. Verdict: do not build it. A table behind `bc2cpp_find_method` would remove at most about
0.15% of the host sweep's run time and 0.05% of optcarrot's, and nearly all misses are first calls, which an epoch does
not remove.

## The question

An owner call (`bc2cpp_owner_call`, 2391 text sites in rpg-maker-clone's closed build) keeps one entry per site: its last
receiver class and argument count, with the method found. A repeat call skips the lookup, but only while mruby's global
method cache `mrb->cache` (256 entries, direct-mapped) still holds the same entry (OWNER_CALL_ICACHE in
`bc2cpp/tools/bc2cpp/symbol_cache.rb`). The proposal was to compare one integer instead: the fork's `mrb->mt_epoch`,
which `mc_clear_by_id`, `mrb_method_cache_clear` and `mrb_mc_clear_by_class` already bump, and to put a registration-time
table behind the seam. That would drop the `mrb->cache` load and hash on every hit, avoid the misses that come from
`mrb->cache` collisions, and be a first step towards a class-id switch.

## What was measured

A scratch build, never committed, counted every owner call. A hit is a call the site's cache answers. A miss is
sorted by why it missed, from the site's own state and `mrb->cache`:

- **cold:** the site's first call, or the first after the site's entry was reset;
- **poly:** the receiver class or argument count differs from the site's last one;
- **state:** the site's entry belongs to another `mrb_state` or another proof epoch;
- **evict:** same class and count, but another (class, name) holds the `mrb->cache` slot;
- **cleared:** the slot was cleared by an invalidation;
- **changed:** the slot holds the same key with a different method.

`rdtsc` timed the miss path, from after the cache check to just before the call. The seam counted its calls and how many
of them `mrb->cache` already held. Both ran on the closed build's host over rpg-maker-clone's host sweep (7 scenarios and
543 maps, 550 processes) and on the optcarrot probe's sealed binary (180 frames, three runs with identical counts).

| | Host sweep | optcarrot, 180 frames |
| --- | ---: | ---: |
| Owner calls | 23,972,234 | 455,100 |
| Site-cache hits | 97.87% | 98.16% |
| Misses | 510,562 | 8,352 |
| cold | 403,130 (79.0%) | 156 |
| poly | 16,133 (3.2%) | 8,192 |
| evict | 91,208 (17.9%) | 4 |
| cleared, state, changed | 91, 0, 0 | 0, 0, 0 |
| Miss path, share of process time | 0.605% | 0.010% |
| Cycles per miss | 2,374 | 40 |
| Seam calls found in `mrb->cache` | 42.6% | 99.98% |
| Process time | 200 Gcycles (550 processes) | 3.55 Gcycles |

The optcarrot misses are one startup loop alternating `Array#object_id` and `Integer#object_id` (4096 each). The seam's
misses in the sweep are mostly first fills: 301,015 of 524,862 calls, about 550 per process.

## Why it does not pay

- **Misses are rare and mostly cold.** The one kind an epoch removes, evictions, is 0.38% of calls in the sweep and 4
  calls in optcarrot. At the average 2,374 cycles per miss (a cold miss costs more, so this over-counts) it is 0.22
  Gcycles, 0.11% of the sweep.
- **The hit path is not the cost either.** The hash is a three-operation macro (`mrb_int_hash_func`), so the epoch
  compare saves about a dozen instructions and one load per hit. At 4 cycles that is 0.09 Gcycles over 23.5M sweep hits
  (0.05%) and 1.8M cycles over optcarrot's 446K hits (0.05%).
- **Owner calls are not where optcarrot's time goes.** It makes 455K of them in 1.2 s: the compiled code calls its own
  entries directly. Its profile is `mrb_val_union`, `render_pixel` and the resumable step protocol (nfcxx#814).
- **The sweep's owner calls are cheap too.** About 44K per process, in processes that run for 360 Mcycles.
- **Cold misses stay.** 79% of the misses are a site's first call, which costs the owner-name match
  (`bc2cpp_owner_listed`, string compares). An epoch does not change that. Only a table built at registration time that
  already knows each owner would, and it would save about 1.7 Mcycles per process (733 cold misses at the average miss cost), about 0.5% of a sweep process.

## If it is built anyway

The fork already carries what makes it sound, so the work would be on the bc2cpp side only:

- `mt_epoch` is bumped by every method-table writer: `mrb_define_method_raw` (class.c, `mc_clear_by_id`), the ROM layer
  install (`mrb_mt_init_rom`), `include_module_at` (`mrb_method_cache_clear`), `mrb_mod_visibility`,
  `mrb_remove_method`, and the GC's free of a class or iclass (`mrb_mc_clear_by_class`), so a class address is reused
  only after a bump. `mrb_method_memo` (kernel.c) already relies on exactly this.
- `include_module_at` bumps only after boot, which is enough: nothing caches during boot.
- An epoch is coarser than `mrb->cache`'s per-name invalidation. The sweep saw 91 cleared slots in 24M calls, so the
  difference is invisible, but a program defining methods at run time would refill every site after each definition.
- `owner_lookup_shapes_check.rb` already writes tables after warm-up and requires compiled == interpreted, so it is the
  check to extend.

What would change the verdict: an engine that is CPU-bound in owner calls, or the aim of removing mruby's method
tables from the closed build, for which the table is a design step and not a speed-up. The rest of that plan is in
rpg-maker-clone's `docs/bc2cpp-vm-free-runtime-plan.md` (Phase 1 and "Method tables").
