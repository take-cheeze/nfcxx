# Moving bc2cpp here from rpg-maker-clone (plan)

Status: proposal, 2026-11-09. Nothing has moved yet. This note is the plan to review before Phase 1 starts.

bc2cpp is rpg-maker-clone's mruby-bytecode-to-C++ compiler (`tools/bc2cpp`). It compiles a closed world, the engine
and the core and gem Ruby of one build, to C++ that runs without the mruby VM. It moves here the way optcarrot's
interpreted configuration did ([realworld.md](realworld.md): "migrated here from rpg-maker-clone's
`tools/optcarrot_probe`"). The compiler and its checks move to nfcxx. rpg-maker-clone becomes its largest consumer and
keeps its game-specific closed world. Compiling bc2cpp's output with nfcxx itself is a later step (Phase 5).

## What moves (rpg-maker-clone `master`, 2026-11-09)

| Piece | Size | Destination |
| --- | --- | --- |
| `tools/bc2cpp/**`: the compiler, `runtime/vm_frames.cxx` and the C++ Fiber runtime | 339 files, about 104K lines of Ruby | `tools/bc2cpp/` |
| `scripts/bc2cpp/*_check.rb` | 285 checks (158 fast, 124 runtime, 1 mutation, 2 review) | about 254 here; the 31 that read the engine gems or the game stay |
| `scripts/bc2cpp/` helpers: reports, benches, `fixture_runtime.rb`, `check_support.rb`, `cxx.rb` | 73 files | here, except `closed_build.bash`, `host_sweep.bash`, `static_dispatch_lists.bash` |
| `scripts/ci/bc2cpp_check_policy.yml` | 1724 lines | split along the same line as the checks |
| `docs/bc2cpp-*.md` | 160 pages | `docs/notes/bc2cpp/`; rpg-maker-clone keeps a short page on consuming bc2cpp |
| `sig/bc2cpp/`, the base RBS | 2 files | `sig/bc2cpp/` |
| `host-libs/mruby-bc2cpp-runner`, `host-libs/mruby-bc2cpp-sources`: bc2cpp built by itself | 2 gems | here |
| `tools/optcarrot_probe`, the compiled configurations | | `tests/realworld/`, next to the interpreted run |

These stay in rpg-maker-clone:
- the `mruby-*-compiled` gem shells;
- the `closed` stanza of `build_config.rb`;
- `closed_build.bash` and `host_sweep.bash`;
- the closed-world lint policy for engine code.

Its 1257 pending `changelog.d/*bc2cpp*` fragments are folded into `CHANGELOG.md` before the move. nfcxx has no changelog
convention.

Both repositories are MIT and owned by the same person. CI here already installs `ruby` and `rake`. bc2cpp also needs the
`prism` 1.9.0 and `rbs` 4.0.0 gems, which rpg-maker-clone's `Gemfile` pins.

## Coupling to cut first, in rpg-maker-clone

1. **The mruby fork.** bc2cpp needs take-cheeze/mruby, not upstream mruby. It depends on ROM method tables,
   `MRB_CORE_CLASS_UNITS`, the frames-only link and found-method calls. 56 bc2cpp files name `3rd/mruby`, and the audits
   pin digests of fork sources: `NativeClassResults::FILES` and `codegen_sort_array_cmp`. Here, `scripts/setup-mruby.sh`
   pins upstream 4.0.0 for the helper scripts, which is a different mruby.
   - Plan: one variable, `BC2CPP_MRUBY_ROOT`, replaces the hard-coded path.
   - bc2cpp gets its own fork pin here.
   - rpg-maker-clone fails CI when its `3rd/mruby` differs from that pin.
   - The pin check matters because a digest mismatch quietly drops facts instead of failing the build. One example:
     `codegen_sort_array_cmp` loses an inline worth 16.9M sends.
2. **Engine gem names.** About 40 bc2cpp files name `mruby-rgss`, `mruby-lcf` or `mruby-rpg2k`, mostly in closed-world gem
   lists and native-result tables. These become a world manifest that the caller passes. The build kinds in
   `compiled_gems.rb` (`closed`, `wio`, `optcarrot-probe`, `bc2cpp-self`) already work this way. Table rows that describe
   one game's natives, such as RGSS entries in `NativeClassResults`, become data that rpg-maker-clone supplies.
3. **`scripts/rpg2k/closed_world_lint.rb`.** It is part of the `bc2cpp-self` program and also gates engine code.
   - It becomes a bc2cpp tool that takes its allowlist from the caller.
   - rpg-maker-clone keeps its own policy.
4. **The check split.** The split follows the capabilities already recorded in the policy.
   - Checks that stay in rpg-maker-clone: the `closed_build` checks (5), plus those that read the engine gems or game
     data (31 in all).
   - The rest need only `mrbc`, `native_sources` (the mruby tree), `core_library`/`full_library` and `cxx`.
   - A `home: nfcxx|rpg` key goes on every policy entry first, so the split is a reviewed diff.

Each item is an ordinary rpg-maker-clone PR that keeps its CI green.

## Phases

### Phase 0: land the in-flight work in rpg-maker-clone

Moving work in progress across two repositories doubles its rebase cost. As of this note, three stacked branches are
verified locally:
- the by-name stage 4 calls;
- the fork's ROM tables for class methods;
- ROM method tables for compiled code.

Each has a closed build, the closed-build checks and a host sweep on Nepheshel. They land before any move, followed by a
short freeze on `tools/bc2cpp` and `scripts/bc2cpp`.

The optcarrot probe regressed about 6× in the first week of November (0.29 s to about 1.7 s for 180 frames). It
moves with the compiler, so the cause should be found first; otherwise the move inherits a regression with no history
attached.
- The drop lies between rpg-maker-clone #3152 and #3177, the start of the VM-free series.
- Inside that window the probe itself did not build (`CONST_RESOLVE`, then invalid generated labels), which is why it
  went unnoticed.

### Phase 1: decouple in place

Coupling items 1 to 4 above. Exit: `tools/bc2cpp` runs from any checkout given `BC2CPP_MRUBY_ROOT` and a world manifest,
and every policy entry has `home:`.

### Phase 2: import with history

- Run `git filter-repo` over rpg-maker-clone, keeping these paths:
  - `tools/bc2cpp`, `scripts/bc2cpp`, `docs/bc2cpp-*`, `sig/bc2cpp`;
  - the two `host-libs/mruby-bc2cpp-*` gems and `tools/optcarrot_probe`.

  Rename them to this layout and merge the result with `--allow-unrelated-histories`. rpg-maker-clone's rule is that
  design rationale lives in commit messages, not in comments, so a plain copy would lose the reasons behind bc2cpp's
  soundness rules.
- Add `3rd/mruby-bc2cpp`, the fork at rpg-maker-clone's pin, and `scripts/setup-bc2cpp.sh`, which installs the gems and
  builds the fork and the host `mrbc`.
- The standalone closed world is the optcarrot probe. It is self-contained, and its pin is already here.
- CI adds a fast-tier job, two or three runtime-tier shards and the optcarrot compiled run. The fork build is cached the
  way `mruby-tool` is.
- Exit: CI here runs every `home: nfcxx` check green.

### Phase 3: rpg-maker-clone consumes nfcxx

- rpg-maker-clone adds `3rd/nfcxx` as a shallow submodule and does not recurse into it: it must not fetch `3rd/edg`,
  `3rd/qbe` or `3rd/cproc`.
  - The alternative is a sparse checkout of `tools/bc2cpp`, `scripts/bc2cpp` and `sig/bc2cpp`.
- `build_config.rb`, the `compiled_gems.rb` callers, `closed_build.bash` and `host_sweep.bash` switch to
  `3rd/nfcxx/tools/bc2cpp`. The in-tree copy is deleted in the same PR, so there is never a second copy to drift.
- These stay in rpg-maker-clone CI:
  - `bc2cpp-build`: the closed build, the base section, the VM-free inventory ceilings and the class-body proof;
  - `bc2cpp-sweep` and `bc2cpp-lists`;
  - the 31 game-bound checks;
  - the fork pin check.
- After this, a bc2cpp change is an nfcxx PR followed by an rpg-maker-clone gitlink bump. That is the flow the mruby
  fork already uses.

### Phase 4: tidy

- rpg-maker-clone's links to `docs/bc2cpp-*` move here.
- The VM-free plan and its inventory table move with bc2cpp. Its ceilings are measured on rpg-maker-clone's closed
  world, so the table is labelled as that world's numbers.
- The AGENTS.md sections on bc2cpp-compiled engine Ruby stay where they are: the closed-world lint and the `mrb_int`
  width rules constrain engine code.

### Phase 5: what nfcxx adds

- Compile bc2cpp's generated C++ with `nfcxx`. It needs C++ exceptions (`MRB_USE_CXX_EXCEPTION`, `lib/ehshim`).
  [cxx-driver.md](cxx-driver.md) already lists the remaining blockers of the rpg-maker-clone desktop build.
- Build the self-compiled bc2cpp with nfcc, as a tool alongside `weak-symbols` and `qbe-prep`.
- Later, emit Path B IR from bc2cpp's IR instead of C++ text.

## Risks

- **Two-repository churn.** bc2cpp is most of rpg-maker-clone's activity (1257 pending changelog fragments). Every fix
  becomes two PRs. The rpg-maker-clone side is only a gitlink bump plus ceiling updates, at a steady cadence.
- **Ceilings measured on the game.** `vm_free_inventory_check` and the owner-call counts live in rpg-maker-clone, but
  changes here move them. An optional job here builds the closed world at a pinned rpg-maker-clone commit.
- **Fork pin drift.** This is why the pin check in Phase 3 is required (item 1).
- **CI time.** bc2cpp's jobs are rpg-maker-clone's slowest. Without a label or a schedule for the runtime tier, nfcxx
  gains about three runner-hours per push.

## Decisions for the owner

1. **History:** a filter-repo import with history (recommended), or a plain copy as with optcarrot.
2. **Consumption:** a shallow, full `3rd/nfcxx` submodule (recommended), or a separate bc2cpp repository later.
3. **Timing:** after Phase 0 (recommended), or now, porting the open branches.
4. **optcarrot's compiled configurations:** move with the compiler (recommended), or stay in rpg-maker-clone.
