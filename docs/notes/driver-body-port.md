# Porting the driver body (`./nfcxx`) to Ruby

Status: in progress (B0 and B1 done; B2 landed but regressed; B3 to B8 not started). Follows
docs/notes/driver-state-design.md (the helpers are done; slices 1 to 8 are merged).

## Latest status

Checked against origin/main af2aa11f3 (after #1348 and #1349 merged).

- `./nfcxx` is 856 lines and 21 top-level functions. The Path B `-c` route and the gcc route now take their commands
  from planner output (`--records --shell` and `--shell`); the bash still evaluates and runs them.
- `scripts/nfcxx.rb` is a pass-through: it copies the frozen oracle `tests/driver-body/nfcxx-bash` and runs it. It
  dispatches no route. Commit `c11d31fb4` (B2) removed the earlier dispatcher and its message does not say so.
- Test state on main: `tests/driver-body` 3 passed; `tests/nfcxx-driver` 11 passed, 7 failed (the failures are the
  dispatch lines the removed dispatcher printed); `tests/nfcxx-trace` 251 passed, 35 failed (the `pathb-plan` route
  checks); `tests/nfcxx-prepass` 28 failing (cause not analysed); `tests/nfcxx-sanitize` exits 1 with no summary.
- Open decisions: (1) was dropping the B2 route dispatch intended? If not, restore it before B3. (2) should the bare
  `cc` at the Path B and C-only link sites become `NFCXX_CC`?
- Not planned in the Ruby driver yet: the Path B link, the cosmo link, the eccp call sites, the `-E`, `--emit-hip`,
  sanitizer and trace setup, `cu_prepare` and `cpp2_prepare` (they rewrite the source list and the trap), and
  `mod_build_program`.
- B8 is blocked. The B8 audit (against 73c5fc40c) concluded that `./nfcxx` cannot become a shim yet.

## Where the body stands

`./nfcxx` was about 1060 lines and 29 functions when this plan was written. The Ruby helpers already do most of the
work it calls. What is left in bash is the top-level flow:

1. Argument records: the planner's `--records` mode (scripts/nfcxx-loop.rb), read into bash variables.
2. Early exits: `--emit-hip`, the SYCL check and run (scripts/nfcxx-sycl.rb), the `-x` and `-MD` checks, the module block.
3. Setup: the backend choice (`default_backend`, `pb_fs_host`, the uname checks), sanitizers, `instantiate`, `cosmo`,
   `freestanding`, host probes, the trace unit.
4. The CUDA and `.cpp2` preparation (`cu_prepare`, `cpp2_prepare`), the cache lookup and store, the Path B and gcc routes.
5. The eccp call (plan, trap, subshell, trace span), the CUDA host-symbol second pass, the depmode step.
6. Traps and temporary directories: `mktemp -d` and `trap ... EXIT` for `cudatmp`, `eccp_dir`, `ctmp`, `tmp`, `ptmp`.
7. Exports and the second pass: `$root/nfcxx` re-run with an environment prefix (kernels with host symbols).

## What must stay in the shell, and what does not

Stays: nothing the callers need as a process property. Ruby can own temporary directories (`Dir.mktmpdir` with `ensure`),
spawn children with an environment (`spawn(env, ...)`), and exit with a status. The bash-only things are:

- the `trap` state, once a Ruby driver owns the cleanup;
- `ensure_tool`, when it is still called as a shell function from a child process of bash;
- the entry point itself: `./nfcxx` must stay a bash file (a shim that runs the Ruby driver) so that existing callers
  (`nfcc`, `bc2cpp`, the CI scripts) keep working unchanged.

So the end state is `./nfcxx` as a shim, `scripts/nfcxx.rb` as the driver, and the old bash kept under tests/ as the
oracle until the suites pass with the Ruby driver.

## Stages

Each stage is one PR. Every stage keeps `./nfcxx` working and is checked against a frozen copy of the bash driver
(the oracle, as in tests/nfcxx-cuda-device/nfcxx-bash and tests/nfcxx/nfcxx-bash), on the full suites:
tests/nfcxx/loop-state.sh, tests/nfcxx/loop-consumer.sh, tests/nfcxx-driver, tests/nfcxx-gcc, tests/nfcxx-pathb,
tests/nfcxx-live, tests/nfcxx-cache, tests/nfcxx-modules, tests/nfcxx-cuda-device, tests/nfcxx-sycl, tests/nfcxx-trace.

- **B0: the plan.** Done.
- **B1: the oracle.** Done: tests/driver-body/nfcxx-bash is the frozen copy, and the body tests point at it.
- **B2: the Ruby skeleton.** `scripts/nfcxx.rb` runs the stages of section "Where the body stands" in order, with each
  step calling the existing helper (no new logic). It is used only when `NFCXX_RUBY_DRIVER=1`. Test: the same suites with the
  flag. Status: landed in B2's form only, which is the pass-through described under "Latest status". The dispatch that
  the earlier CRuby driver ran (before c11d31fb4) is gone; restoring it or not is an open decision.
- **B3: the setup stage.** Not started. Blocked on the B2 decision above. The backend, sanitizer, cosmo, freestanding and host-probe decisions move into Ruby (most are
  already in scripts/nfcxx-loop.rb and the planners).
- **B4: the CUDA, `.cpp2` and module stages.** These are already one call each; the Ruby driver calls them with the state
  it has. Not started. Note: `cu_prepare` and `cpp2_prepare` still rewrite the source list in bash.
- **B5: the cache and the eccp call.** Already one call each (slice 7 and 8). Move the call sites. Not started.
- **B6: traps and temporary directories.** Ruby owns them (`Dir.mktmpdir`, `ensure`). Test: the cleanup cases in
  tests/nfcxx-link and tests/nfcxx-modules/trap.sh. Not started.
- **B7: the second pass and the exports.** Ruby spawns the second run with the environment; the exports go into the Ruby
  process environment. Not started.
- **B8: the switch.** `./nfcxx` becomes a shim that runs `scripts/nfcxx.rb`, the flag becomes the default, and the bash
  body moves to tests/driver-body/nfcxx-bash (kept as the oracle). Blocked: see "Latest status" and the B8 audit.

## Risks

- **Behaviour in failures.** Every bash `|| exit $?` must keep its status. The status chain (section 7 of
  driver-state-design.md) becomes `ensure` plus `exit`.
- **Process startup.** Ruby is already started several times per compile; moving the whole body into one Ruby process
  reduces that. Check the timing on tests/nfcxx-live before and after.
- **macOS.** The driver runs on macOS (Path B probes); the Ruby driver must not assume GNU tools (`realpath -m`, `date %N`).
- **CI.** The bc2cpp scope check (tests/ci/scope_check.rb) must list the new Ruby files as plain `.rb` paths in
  .github/workflows/ci.yml.
