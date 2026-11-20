# Porting the driver body (`./nfcxx`) to Ruby

Status: in progress. B0 to B7 are done; B8 (the switch) is the next step and is not done. Follows
docs/notes/driver-state-design.md (the helpers are done; slices 1 to 8 are merged).

## Latest status

Checked against origin/main 1aa750d8b (after #1387 merged).

- `./nfcxx` is still the bash driver. With `NFCXX_RUBY_DRIVER=1` it runs `scripts/nfcxx.rb`, which does the refusals,
  the cache configuration, the temporary directories and traps, and the second pass in Ruby, and runs the frozen
  oracle `tests/driver-body/nfcxx-bash` for the rest.
- Done: B0 to B7 (see "Stages"). The route dispatch is restored (pre-loop plan and gcc refusals), and the Path B plan
  dispatch landed in #1387.
- The text-reading suites point at the frozen body (#1385). `tests/nfcxx-sanitize` is retired; its check is
  `tests/driver-sanitize`.
- Decided: the cache key hashes `tests/driver-body/nfcxx-bash` after B8. The six suites are pinned (pinned copies).
- Not done: B8. It is the next step; see "Stages".

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
- **B2: the Ruby skeleton.** Done. `scripts/nfcxx.rb` runs under `NFCXX_RUBY_DRIVER=1`. The route dispatch (pre-loop plan
  and gcc refusals) is restored, and the Path B plan dispatch is in (#1387).
- **B3: the setup stage.** Done (#1356): the setup refusals are in Ruby.
- **B4: the CUDA, `.cpp2` and module stages.** Done (#1363): their refusals are in Ruby.
- **B5: the cache and the eccp call.** Done (#1369): the cache configuration refusal is in Ruby. The eccp refusals were
  already on the gcc route.
- **B6: traps and temporary directories.** Done (#1364): Ruby owns them (`Dir.mktmpdir`, removed when the run ends). This
  is the temporary-directory leak fix.
- **B7: the second pass and the exports.** Done (#1372): the second run goes through a Ruby helper.
- **B8: the switch.** Not done; the next step. `./nfcxx` becomes a shim that runs `scripts/nfcxx.rb`, the flag becomes
  the default, and the frozen body in tests/driver-body/nfcxx-bash stays the oracle. The cache key hashes that file
  after B8.

## Risks

- **Behaviour in failures.** Every bash `|| exit $?` must keep its status. The status chain (section 7 of
  driver-state-design.md) becomes `ensure` plus `exit`.
- **Process startup.** Ruby is already started several times per compile; moving the whole body into one Ruby process
  reduces that. Check the timing on tests/nfcxx-live before and after.
- **macOS.** The driver runs on macOS (Path B probes); the Ruby driver must not assume GNU tools (`realpath -m`, `date %N`).
- **CI.** The bc2cpp scope check (tests/ci/scope_check.rb) must list the new Ruby files as plain `.rb` paths in
  .github/workflows/ci.yml.
