# Moving bc2cpp here from rpg-maker-clone (plan)

Status, 2026-11-09: in progress.
- Done: optcarrot under this repository's CI (`tests/bc2cpp/run_optcarrot.sh`).
- Done: Phase 1's root split, rpg-maker-clone#3203.
- Done: Phase 2's import. bc2cpp is in `bc2cpp/` with its history, and the optcarrot world now uses it.
- Done: the fixture checks run here: the `checks` job of `.github/workflows/ci.yml`, three shards of
  `bc2cpp/scripts/bc2cpp/checks.list`, run inside the pinned world with its `3rd/nfcxx` pointed at this checkout.
- Done: a second world, `scripts/pathb-qbe-emit.rb` (`tests/bc2cpp/run_pathb_qbe_emit.sh`, the `script-world` build kind).
- Done: a third world, `scripts/pathb-borrowck.rb` (`tests/bc2cpp/run_pathb_borrowck.sh`). Its top level is `main(argv)`,
  which returns the status, and its one regex literal is a character scan (the script needs no `Regexp`; the canonical closed world leaves out `mruby-onig-regexp`, see below). The interpreted
  script is unchanged: 3598 runs of `tests/pathb-borrow` in every mode give the same stdout, stderr and status before and after.
  Two bc2cpp defects surfaced on it:
  - **Fixed: by-name results were not GC-rooted.** mruby's funcall restores the arena before it returns, so the result of
    `mrb_funcall_with_method` / `mrb_funcall_argv` (owner calls, the funcall helpers, the numeric slow paths) was unprotected
    until stored. The next allocation could collect it. Valgrind showed the GC marking freed objects during
    `LocalLifetime#byte_key` (`"byte:" + x.to_s + ...`). Every such helper now returns through `bc2cpp_keep_call`
    (bc2cpp.rb, symbol_cache.rb, codegen_numeric_slow.rb and the other codegen files).
  - **Open: frame-local blocks.** With `--infer-summaries`, the compiled `Enumerable#all?` (fork mrblib, `all?(pat=NONE, &block)`)
    yields a `Bc2cppBlock` (a block on the C stack) through `Array#each`. The block fallback reads its `block` upvar through
    a pointer to a register of `all?`'s frame, and the read is wrong (valgrind: invalid read in `mrb_vm_find_method` on a
    garbage receiver). `BC2CPP_STACK_BLOCKS=0` makes all 11 such cases pass, so the stack-block path is the trigger. The
    exact mechanism is not yet found. The world sets the knob, so it checks the heap-block build; the stack-block build is
    covered by optcarrot only.
- Next: rpg-maker-clone takes bc2cpp from its `3rd/nfcxx` submodule (rpg-maker-clone#3204, Phase 3).

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

## First step: optcarrot compiled here, with bc2cpp pinned (done)

Before any code moves, bc2cpp compiles a world under this repository's CI. That shows what CI here needs (Ruby 4.0
and the host compiler, no EDG toolchain) and puts the optcarrot probe, which rpg-maker-clone runs in no CI job, under a
check.
- `tests/bc2cpp/fetch.sh` makes a shallow checkout of rpg-maker-clone at a pinned commit, with only the five
  submodules bc2cpp and the worlds read (the mruby fork, mruby-onig-regexp, mruby-stringio, mruby-marshal, optcarrot),
  in `build/bc2cpp/`. Bumping bc2cpp is a one-line change of that pin.
- `tests/bc2cpp/run_optcarrot.sh` builds the probe's host `mrbc` and runs rpg-maker-clone's own runner
  (`tools/optcarrot_probe/compiled_run.rb 180`): optcarrot on CRuby, on CRuby with YJIT, on the mruby interpreter, and as
  a sealed mruby build whose Ruby bc2cpp compiled to C++.
- The check is checksum 59662 on every runtime. The script prints each runtime's frames per second and the compiled
  build's hot-path speedup over the interpreter. `OPTCARROT_MIN_SPEEDUP=X` also fails below X; it is off by default.
- `.github/workflows/ci.yml` runs every world, when `tests/bc2cpp/` changes or on demand, three worlds to a job
  (`tests/bc2cpp/worlds.list`, balanced by weight by `tests/bc2cpp/run_worlds.rb`).

At the first pin (rpg-maker-clone `df3ee7c52`, 32-core desktop, host gcc 15), 180 frames took:

| Runtime | Seconds |
| --- | ---: |
| CRuby | 2.89 |
| CRuby + YJIT | 0.89 |
| mruby interpreter | 7.77 |
| bc2cpp | 1.61 |

The hot-path speedup over the interpreter is 4.4×, down from about 28× before rpg-maker-clone #3174 (see Phase 0).
The gate stays off until that regression is fixed. The whole script runs in about 2 minutes there.

## Adding a world

A world is a program bc2cpp compiles as a closed world, plus a check that its compiled build behaves like the
interpreter. Each world is one `tests/bc2cpp/run_<name>.sh` that sources `fetch.sh`, plus one line in
`tests/bc2cpp/worlds.list` (the world, its weight in minutes, and optionally its `BC2CPP_MRBC_RB` mode). The workflow's `world`
job runs the list in shards (`run_worlds.rb --shard N/3`): a new world needs no workflow change until the shards
outgrow their timeout.

The second world is one of nfcxx's own mruby scripts ([mruby-scripting.md](mruby-scripting.md)):
`scripts/pathb-qbe-emit.rb`, the largest (3.5K lines) and the one with the heaviest real input (the 3.4 MB IR of
`tests/pathb-ir`). Its rules fit a closed world: it uses no `Regexp`, byte strings, no `eval`.
- **Build kind.** `script-world` is a probe build like `optcarrot-probe` (`BC2CPP_PROBE_BUILDS` in `compiled_gems.rb`): the
  script is the mrblib of a gem, its closing statements (`rc = main(ARGV); exit(rc)`) become `ScriptWorld.run`, and a
  fixed C `main` passes `ARGV` and returns its status. It builds on the pinned world's mruby fork with the same sealed
  gem set, without `mruby-onig-regexp`.
- **Runner.** `bc2cpp/tools/script_world/compiled_run.rb` takes the script, its tail, a file of cases and benchmark
  arguments. It checks that every case gives the same stdout, stderr and exit status compiled as interpreted (an
  uncaught exception compares without its backtrace: compiled code has no line table), then times the interpreter, the
  compiled build and CRuby.
- **Another script** needs its own `tests/bc2cpp/run_<name>.sh` (the tail, the entry, the cases), nothing else, as long as
  the script's inputs are files given on the command line.

### Regexp in a closed world

`Regexp` is a build-profile choice, not a limit of the compiler. `mruby-onig-regexp` bundles Onigmo, the engine CRuby
uses. The runner build already includes it (`host-libs/mruby-bc2cpp-runner/build_config.rb`), `mruby-prism` and
`mruby-rbs` depend on it, and bc2cpp knows its owner class `OnigMatchData` (`tools/bc2cpp/index_closed_planner.rb`).
The canonical closed world leaves it out on purpose (`tools/bc2cpp/compiled_gems.rb`, `BC2CPP_CANONICAL_CORE_GEMS`).

To compile a world that uses `Regexp`:
1. Put `mruby-onig-regexp` in that world's gem set instead of dropping it.
2. Check that the closed-world scan and native-symbol analysis accept its sources (`scripts/bc2cpp/analysis_headers.rb`
   already writes the Onigmo header overlay).
3. Compare compiled and interpreted output on regex-heavy cases: `=~`, `match`, `scan`, `gsub` with a block, `$~`/`$1`,
   named captures, encodings.

Not yet done: no world compiles `Regexp` code, so step 3 has no evidence yet. The open frame-local block bug above
(`all?` through `Array#each`) is the likeliest obstacle, since `scan`/`gsub` take blocks.

## Scope: Rails and Discourse

Not a target today. Rough assessment, not measured (no Discourse size count yet):
- **Closed world vs. Rails.** Rails loads code at runtime (Zeitwerk autoload, `require` during boot) and relies on
  `class_eval`, `define_method` and `method_missing`. bc2cpp's closed-world rules forbid `eval`, `define_method` and late
  C installs (`docs/notes/bc2cpp-core-c.md`). Its codegen special-cases some of these; it does not remove them.
- **Regexp.** Solvable with onig as above, and not a structural blocker.
- **Native extensions.** Discourse depends on C extensions such as `pg` and `nokogiri`. bc2cpp has no path for them.
- **Server runtime.** Threads, sockets, a PostgreSQL client and Redis are outside the closed-world model.
- **Size.** The validated worlds (optcarrot, the RPG engine, the Path B script) are self-contained pure Ruby. A Rails
  app plus gems is likely much larger; measure before planning (`cloc`, and a grep for `eval`, `define_method`, `Regexp`).

A realistic first target is a pure-Ruby, eval-free leaf library with no native gems, built the optcarrot way: a pinned
source, a world manifest, and a check against CRuby.

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

Done for the code. `bc2cpp/` holds `tools/bc2cpp`, `scripts/bc2cpp`, `tools/optcarrot_probe`, `scripts/optcarrot` and the
`host-libs/mruby-bc2cpp-*` gems, merged with the 4053 rpg-maker-clone commits that touch them. Its two roots
(`bc2cpp/tools/bc2cpp/world_root.rb`) are this tree and the world. `tests/bc2cpp/run_optcarrot.sh` sets both: this tree,
and the pinned rpg-maker-clone checkout. It passes with that checkout's own copy of bc2cpp removed.

Original plan:


- Run `git filter-repo` over rpg-maker-clone, keeping these paths:
  - `tools/bc2cpp`, `scripts/bc2cpp`, `docs/bc2cpp-*`, `sig/bc2cpp`;
  - the two `host-libs/mruby-bc2cpp-*` gems and `tools/optcarrot_probe`.

  Rename them to this layout and merge the result with `--allow-unrelated-histories`. rpg-maker-clone's rule is that
  design rationale lives in commit messages, not in comments, so a plain copy would lose the reasons behind bc2cpp's
  soundness rules.
- Add `3rd/mruby-bc2cpp`, the fork at rpg-maker-clone's pin, and `scripts/setup-bc2cpp.rb`, which installs the gems and
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
