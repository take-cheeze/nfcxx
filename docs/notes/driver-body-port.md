# Porting the driver body (`./nfcxx`) to Ruby

Status: B8 done (the switch, #1402): `./nfcxx` is a shim that runs `scripts/nfcxx.rb`. The bash body is frozen at
`tests/driver-body/nfcxx-bash`, and the Ruby driver runs it for every stage that is not yet ported. Follows
docs/notes/driver-state-design.md (the helpers are done).

## Latest status

Checked against origin/main after #1432 (the compile cache's lookup planner).

- `./nfcxx` is a 4-line shim. `scripts/nfcxx.rb` does the route dispatch and the refusals (the setup refusal, the
  `.cu`/`.cpp2`/module refusal, the cache configuration refusal, the gcc plan, the Path B plan), then runs the frozen body
  `tests/driver-body/nfcxx-bash` (1089 lines) as its oracle for the rest.
- Merged slices, by PR: setup refusals (#1356), CUDA/`.cpp2`/module refusals (#1363), cache configuration refusal (#1369),
  second-pass helper (`scripts/nfcxx-second-pass.rb`, #1372), temporary-directory leak fix (#1364), trace exit status (#1378),
  Path B dispatch with CHECK and STORE lines (#1387), the switch (#1402), and the compile cache's lookup planner
  (`scripts/nfcxx-cache-plan.rb`, #1432).
- The frozen body still does these in bash, and the Ruby driver calls them through the body: argument records (now evaluated from
  `scripts/nfcxx-loop.rb --bash-state`), `--emit-hip`, the `-x` and `-MD` checks, the module block (planned by
  `scripts/nfcxx-modules-plan.rb`, called from the body), the
  backend choice and host probes (`default_backend`, `pb_fs_host`, the uname checks), sanitizers, `instantiate`, `cosmo`,
  `freestanding`, the trace unit, `cu_prepare`, `cpp2_prepare`, the cache hit and store (`cache_check`, `cache_store`), the
  eccp call (`eccp_plan`, its trap and its trace span), the depmode step, the CUDA host-symbol second pass, and the second run
  with an environment prefix.
- The SYCL two-pass build (`scripts/nfcxx-sycl.rb`) now runs in `scripts/nfcxx.rb`, before the body starts:
  the body's early exits never refuse its arguments. `tests/driver-sycl-dispatch` holds the goldens.
- Helpers still defined in the body: `temp_cleanup`, `abs_path`, `onoff`, `ensure_tool`, `ecp_args`, `state_put`,
  `loop_set`/`loop_append`, `eccp_cleanup`, `compile_clean`, `link_records_rm`, `cache_log`, `cache_sha`, `cache_remote_get`,
  `cache_remote_put`.

## What blocks deleting the frozen body

The body can be deleted only when the Ruby driver runs every stage without it. In order:

1. **Argument records.** Mostly done. `scripts/nfcxx.rb` runs `scripts/nfcxx-loop.rb --bash-state` before the routes (design
   (a): the result goes to the body in the environment, `NFCXX_LOOP_STATUS` and `NFCXX_LOOP_STATE`, and the body evals it at
   its loop's place, so a refusal is printed where it was). The body runs the loop itself only when the Ruby driver did not:
   when the arguments name `--bundle-*`, `--cuda-driver=` or `libcuda`, because the body's wrappers rewrite them first
   (`scripts/wrap.sh`, which still runs in the body). Porting those wrappers to `scripts/nfcxx.rb` (they are `scripts/wrap.rb`
   calls, with the EXEC and CONTINUE results) removes the fallback and the body's loop.
2. **Early exits.** `--emit-hip`, the `-x` and `-MD` checks. The module block is planned in Ruby
   (`scripts/nfcxx-modules-plan.rb`: scans, refusals, the module build of a link, the compile's module options); the body
   only calls it at the block's place and ends with the build's status.
3. **Setup.** The backend choice, sanitizers, `instantiate`, `cosmo`, `freestanding`, host probes and the trace unit.
   Most of the decisions are already in the planners; the bash only calls them.
4. **CUDA and `.cpp2` preparation.** Done for the decisions and the rewriting: `scripts/nfcxx-cu-cpp2-prepare.rb` (cu and cpp2)
   makes the copies, the rewrite and the translation, and the array edits, and the body evals its statements at the
   preparation's place. The body still makes the temporary directory and its EXIT trap (item 8).
5. **Cache hit and store.** `cache_check` and `cache_store` call the Ruby helpers; the remote tier (`cache-io`) and the
   `--cache-log` writes are called from bash.
6. **Routes.** The gcc route and the Path B `-c` and link routes still evaluate their planner output in bash.
7. **eccp call.** The plan, trap, subshell and trace span, then the depmode step and the CUDA host-symbol second pass.
8. **Temporary directories and traps.** The Ruby driver already owns the temporary root (`Dir.mktmpdir`); the bash
   `trap ... EXIT` lines for `cudatmp`, `eccp_dir`, `ctmp`, `tmp` and `ptmp` must move to it.
9. **Second run and exports.** The `$root/nfcxx` re-run with an environment prefix moves into Ruby (`spawn(env, ...)`).
10. **Test oracles.** The frozen copies under `tests/` (`tests/driver-body/nfcxx-bash`, `tests/nfcxx/nfcxx-bash`,
    `tests/nfcxx-cache/nfcxx-bash`, `tests/nfcxx-cuda-device/nfcxx-bash`) are read by suites, and some suites extract
    functions from them with `sed`. Each suite must be moved to a pinned copy or to the Ruby code before its oracle is deleted.

Items 1 to 9 are code; item 10 is test layout. Item 10 can be done suite by suite, as each suite stops reading an oracle.

## What must stay in the shell, and what does not

Stays: nothing the callers need as a process property. Ruby can own temporary directories (`Dir.mktmpdir` with `ensure`),
spawn children with an environment (`spawn(env, ...)`), and exit with a status. The bash-only things are:

- the `trap` state, once a Ruby driver owns the cleanup;
- `ensure_tool`, when it is still called as a shell function from a child process of bash;
- the entry point itself: `./nfcxx` must stay a bash file (a shim that runs the Ruby driver) so that existing callers
  (`nfcc`, `bc2cpp`, the CI scripts) keep working unchanged.

So the end state is `./nfcxx` as a shim, `scripts/nfcxx.rb` as the driver, and the old bash removed once the items above
are done.

## Stages

Each stage is one PR. Every stage keeps `./nfcxx` working and is checked against the frozen body (the oracle), on the
suites that exercise its stage. Stage status:

- **B0: the plan.** Done.
- **B1: the oracle.** Done: `tests/driver-body/nfcxx-bash` is the frozen copy, and the body tests point at it.
- **B2: the Ruby skeleton.** Done: `scripts/nfcxx.rb` runs the frozen body, and its route dispatch is back (#1352, #1387).
- **B3: the setup stage.** Refusals done (#1356). The setup itself still runs in the body (item 3 above).
- **B4: the CUDA, `.cpp2` and module stages.** Refusals done (#1363). `cu_prepare` and `cpp2_prepare` make their copies and
  translations in Ruby (`scripts/nfcxx-cu-cpp2-prepare.rb`); the body keeps their trap (item 4 above).
- **B5: the cache.** Configuration refusal done (#1369). The lookup planner is done (#1432). The hit, store and remote
  calls still run in the body (item 5 above).
- **B6: traps and temporary directories.** The Ruby driver owns the temporary root, and the leak fix is merged (#1364).
  The body still has the trap lines for the eccp and CUDA directories (item 8 above).
- **B7: the second pass.** The second-pass helper is merged (#1372). The second run itself is still in the body (item 9).
- **B8: the switch. Done (#1402).** `./nfcxx` is a shim (`"${RUBY:-ruby}" "$(dirname "$0")/scripts/nfcxx.rb" "$@"`). The
  Ruby driver is the entry point, and the `NFCXX_RUBY_DRIVER` gate is gone. The operational bash body is
  `tests/driver-body/nfcxx-bash` (frozen; `scripts/nfcxx.rb` runs it as its oracle). The cache key hashes
  `tests/driver-body/nfcxx-bash` (`scripts/nfcxx-cache.rb`), not `./nfcxx`. `tests/driver-body/run.sh` no longer diffs
  the body against `./nfcxx` (that text is now a shim). Suites that read `./nfcxx` text use a pinned copy of the pre-switch
  file (`pinned-*.txt`, taken at 25005e00d).

## Risks

- **Behaviour in failures.** Every bash `|| exit $?` must keep its status. The status chain (section 7 of
  driver-state-design.md) becomes `ensure` plus `exit`.
- **Process startup.** Ruby is already started several times per compile; moving the whole body into one Ruby process
  reduces that. Check the timing on tests/nfcxx-live before and after.
- **macOS.** The driver runs on macOS (Path B probes); the Ruby driver must not assume GNU tools (`realpath -m`, `date %N`).
- **CI.** The bc2cpp scope check (tests/ci/scope_check.rb) must list the new Ruby files as plain `.rb` paths in
  .github/workflows/ci.yml.
