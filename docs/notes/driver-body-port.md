# Porting the driver body (`./nfcxx`) to Ruby

Status: B8 done (the switch, #1402): `./nfcxx` is a shim that runs `scripts/nfcxx.rb`. The bash body is frozen at
`tests/driver-body/nfcxx-bash`, and the Ruby driver runs it for every stage that is not yet ported. Follows
docs/notes/driver-state-design.md (the helpers are done).

## Latest status

Checked against origin/main after #1529 (b2c5b7ef6).

- `./nfcxx` is a 4-line shim. `scripts/nfcxx.rb` does the route dispatch and the refusals (the setup refusal, the
  `.cu`/`.cpp2`/module refusal, the cache configuration refusal, the gcc plan, the Path B plan). Before the body runs, it runs
  the argument loop (`scripts/nfcxx-loop.rb --bash-state`), the wrappers (`scripts/wrap.rb bundle` and `scripts/wrap.rb
  cuda-driver`), and the SYCL two-pass build (`scripts/nfcxx-sycl.rb`). It then runs the frozen body
  `tests/driver-body/nfcxx-bash` (918 lines, 23 functions) as its oracle for the rest.
- Merged slices, by PR: setup refusals (#1356), CUDA/`.cpp2`/module refusals (#1363), cache configuration refusal (#1369),
  second-pass helper (`scripts/nfcxx-second-pass.rb`, #1372), temporary-directory leak fix (#1364), trace exit status (#1378),
  Path B dispatch with CHECK and STORE lines (#1387), the switch (#1402), the compile cache's lookup planner
  (`scripts/nfcxx-cache-plan.rb`, #1432), the early-exit planner (`scripts/nfcxx-early-exit.rb`, #1438), the driver's owned
  temporary directories (#1499, #1505), the CUDA second run's gate and its rewrite of the body's line (#1517), the eccp
  cleanup that skips a directory the driver owns (#1519), the removal of `onoff` (#1520), and the gcc fallback, where the
  body hands the driver a marker and the driver re-runs with `NFCXX_BACKEND=gcc` (#1523).
- The frozen body still does these in bash, and the Ruby driver calls them through the body: the early-exit checks (the body
  runs `scripts/nfcxx-early-exit.rb pre` before the `-E` route, where status 3 is `--emit-hip`, and `post` after it), the
  module block (planned by `scripts/nfcxx-modules-plan.rb`, called from the body), the `cu_prepare` and `cpp2_prepare`
  calls (their copies are made by `scripts/nfcxx-cu-cpp2-prepare.rb`), the cache lookup and store (`cache_check` and
  `cache_store` call `scripts/nfcxx-cache-check.rb`), the eccp call (`eccp_plan`, `eccp_run`, its EXIT trap and its trace span),
  the depmode step, and the CUDA host-symbol gate (`scripts/nfcxx-second-pass.rb plan`, #1517). The driver rewrites the body's
  second-run line, so that run is the Ruby driver (see item 9).
- The setup's statements are planned by Ruby on the argument loop's state (`NfcxxSetupArgs.planned_state`), and the body evals
  them. The default backend (`scripts/nfcxx-setup.rb` default step: the default backend and `pb_fs_host`) goes in
  `NFCXX_SETUP_DEFAULT`, and the stage after the emit-C route (the `-fsanitize=` names, `-fsafe-pointers`, the Path B override
  and their refusals) goes in `NFCXX_SETUP_STAGE_STATUS` and `NFCXX_SETUP_STAGE`. The body plans them itself when the driver
  gave no state (the wrappers' arguments). `tests/driver-setup-stage` checks the argument lists against recordings of the bash
  setup.
- The sanitizer check and `asan_c`, the Path B `pb_flags` tail, the backend environment and the trace unit are also planned
  by Ruby and passed in `NFCXX_SETUP_ASAN_STATUS` and `NFCXX_SETUP_ASAN`, `NFCXX_SETUP_FLAGS`,
  `NFCXX_SETUP_BACKEND_ENV_STATUS` and `NFCXX_SETUP_BACKEND_ENV`, and `NFCXX_SETUP_TRACE_UNIT`. This is merged in c325d76cd.
  `flags_text` in `scripts/nfcxx-setup.rb` is called by `scripts/nfcxx-setup-args.rb`, so it is no longer unwired.
- The setup's rest is planned by Ruby too (`NfcxxSetup.rest`, the `rest` step of `scripts/nfcxx-setup.rb`): the template
  instantiation, `--cosmo`, the freestanding or hosted headers, the host cflags, the GNU options, `--target=linux_k1om` and
  `--target`, and the export of `EDG_CPFE_DEFAULT_OPTIONS`, in the bash's order. The driver passes its statements up to a refusal
  in `NFCXX_SETUP_REST`, with the refusal's status and message in `NFCXX_SETUP_REST_STATUS` and `NFCXX_SETUP_REST_ERR`. The
  hosted headers' probe is timed by the planner, and the body writes its span (`trace_range`, trace.sh) where the bash did, so a
  span is recorded only by a body that reaches the setup (a `-E` or `-fsyntax-only` command is not planned by the driver).
  `tests/driver-setup-rest` checks 66 argument lists (`cases.txt`) against recordings of the bash setup, and the body's protocol.
- The SYCL two-pass build (`scripts/nfcxx-sycl.rb`) runs in `scripts/nfcxx.rb`, before the body starts, so the body's early
  exits never refuse its arguments. `tests/driver-sycl-dispatch` holds the goldens.
- Helpers still defined in the body (checked with grep on origin/main): `temp_cleanup`, `fallback_gcc`,
  `abs_path`, `cu_prepare`, `cpp2_prepare`, `ensure_tool`, `ecp_args`, `state_put`, `eccp_plan_input`,
  `eccp_plan`, `eccp_cleanup`, `eccp_run`, `modules_plan_input`, `loop_no_value`, `early_rec`, `early_records`,
  `preprocess_records`, `cache_plan`, `cache_check`, `cache_store`, `compile_clean`, `link_records_rm`. Not defined in the body:
  `onoff` (removed, #1520), `loop_set`, `loop_append`, `cache_log`, `cache_remote_get`, `cache_remote_put` and `cache_sha`
  (`cache_sha` removed: it had no caller in the body).

## What blocks deleting the frozen body

The body can be deleted only when the Ruby driver runs every stage without it. In order:

1. **Argument records and wrappers.** Done except for one case. `scripts/nfcxx.rb` runs `scripts/nfcxx-loop.rb --bash-state`
   before the routes (design (a): the result goes to the body in the environment, `NFCXX_LOOP_STATUS` and `NFCXX_LOOP_STATE`,
   and the body evals it at its loop's place, so a refusal is printed where it was). The wrappers are already Ruby calls
   (`scripts/wrap.rb bundle` and `scripts/wrap.rb cuda-driver`, run before the body). The driver leaves LOOP_RESULT nil when
   the arguments match `/--bundle-|\A--cuda-driver=|libcuda/`, and then the body runs its own loop. Deleting the body needs
   that case in Ruby. The live body no longer sources `scripts/wrap.sh`; the three older frozen copies still do
   (`tests/nfcxx/nfcxx-bash`, `tests/nfcxx-cache/nfcxx-bash`, `tests/nfcxx-cuda-device/nfcxx-bash`).
2. **Early exits.** `scripts/nfcxx-early-exit.rb` plans them (#1438). The body calls it twice: `pre` (status 2 is a refusal,
   status 3 is the `--emit-hip` route) before the `-E` route, and `post` (the refusals after the route: stdin without `-E`,
   `-x`, dependency files without `-c`, the EDG build, the dialect) after it. The driver does not call
   `nfcxx-early-exit.rb`, so the pre check is still in the body on origin/main; the driver-side pre check in #1528 is not
   merged. The module block is planned in Ruby (`scripts/nfcxx-modules-plan.rb`: scans, refusals, the module build of a link,
   the compile's module options); the body only calls it at the block's place and ends with the build's status.
3. **Setup.** Planned in Ruby, and the body evals the statements: the default backend (`NFCXX_SETUP_DEFAULT`), the stage after
   the emit-C route (`NFCXX_SETUP_STAGE_STATUS`, `NFCXX_SETUP_STAGE`), the sanitizer check and `asan_c` (`NFCXX_SETUP_ASAN_STATUS`,
   `NFCXX_SETUP_ASAN`), the `pb_flags` tail (`NFCXX_SETUP_FLAGS`), the backend environment (`NFCXX_SETUP_BACKEND_ENV_STATUS`,
   `NFCXX_SETUP_BACKEND_ENV`), the trace unit (`NFCXX_SETUP_TRACE_UNIT`), and the rest (`NFCXX_SETUP_REST_STATUS`,
   `NFCXX_SETUP_REST`, `NFCXX_SETUP_REST_ERR`: `instantiate`, the `cosmo` block, the freestanding and hosted header probes with
   their trace span, the host cflags, the GNU options, the k1om and target blocks, the `EDG_CPFE_DEFAULT_OPTIONS` export). The
   bash for each of these stays in the body for a run with no driver state. `planners_text` in `scripts/nfcxx-setup.rb` is
   still unwired (its only caller is that script's own command line); it is superseded by `NfcxxSetup.rest`, which times the
   probe's span in the body rather than in the driver, so the span is recorded only by a body that reaches the setup.
4. **CUDA and `.cpp2` preparation.** Done for the decisions and the rewriting: `scripts/nfcxx-cu-cpp2-prepare.rb` (cu and cpp2)
   makes the copies, the rewrite and the translation, and the array edits, and the body evals its statements at
   `cu_prepare`'s and `cpp2_prepare`'s places. Both functions remain in the body as those callers. Their temporary directory
   is the driver's `NFCXX_OWNED_CUDATMP` (item 8).
5. **Cache lookup and store.** `cache_check` and `cache_store` call `scripts/nfcxx-cache-check.rb` (`check` and `store`), which
   plans the lookup (`scripts/nfcxx-cache-plan.rb`, #1432) and calls `scripts/nfcxx-cache-io.rb` for the `--cache-log` line
   (`log`), the remote tier's fetch on a local miss (`remote-get`) and its put after a store (`remote-put`). The body does not
   call `cache-io` directly, and it no longer defines `cache_log`, `cache_remote_get` or `cache_remote_put`. What remains in the
   body: `cache_plan` prints the lookup's records, and `cache_check` exits 0 on a hit.
6. **Routes.** The gcc route and the Path B `-c` and link routes still evaluate their planner output in the body (its gcc
   compile lines, about line 681, and its Path B route, which passes `pb_flags` to `scripts/pathb-cc.rb`). The gcc fallback is `fallback_gcc` (#1523): under the driver, the body writes its
   message to the marker file and exits 0, and the driver prints it and re-runs `./nfcxx` with `NFCXX_BACKEND=gcc`. Without
   the marker it re-executes itself, as before.
7. **eccp call.** `eccp_plan` (`scripts/nfcxx-eccp-plan.rb`) and `eccp_run` (`scripts/nfcxx-eccp-run.rb`, which runs the
   command in `eccp_cd`) are called from the body, with its EXIT trap (`eccp_cleanup`, which calls `scripts/nfcxx-link.rb
   cleanup`) and its trace span. `eccp_dir` is still made by the body with `mktemp -d` (about line 861); its trap skips it when
   the driver owns the root (#1519). Still in the body: the `moves` decision (`moves=1` for a compile that is not `-c`, which
   `ecp_args` needs before the plan), the trace spans, the depmode step, and the CUDA host-symbol gate (item 9).
8. **Temporary directories and traps.** The Ruby driver makes four directories under the temporary root it owns
   (`Dir.mktmpdir`): `NFCXX_OWNED_CUDATMP`, `NFCXX_OWNED_TMP`, `NFCXX_OWNED_CTMP` and `NFCXX_OWNED_PTMP` (#1499, #1505). It sets
   `NFCXX_TMP_OWNED=1` and removes them when the run ends (#1364). The body uses them when it has them, and otherwise makes its
   own with `mktemp -d` and an EXIT trap, which is only for a run without the driver. Those fallback lines remain in the body
   (about lines 177-178, 209, 538-539, 663-664 and 783-784). Still made by the body: `eccp_dir` (about line 861, with the
   `eccp_cleanup` trap) and `modplan` (about line 419, which the body removes itself on both exits, lines 422 and 435).
9. **Second run and exports.** The CUDA second pass's gate is planned by `scripts/nfcxx-second-pass.rb plan` (#1517), and the
   gate and its second-run line are still in the body (about lines 900-910). The driver rewrites that line
   (`NfcxxSecondPass.oracle_text`, `scripts/nfcxx-second-pass.rb run`), so the live second run is the Ruby driver with the same
   environment and arguments, and the body's trace span still wraps it. Deleting the body needs the gate in Ruby too.
10. **Test oracles.** 26 files under `tests/` name `tests/driver-body/nfcxx-bash`, and the frozen copies under `tests/`
    (`tests/driver-body/nfcxx-bash`, `tests/nfcxx/nfcxx-bash`, `tests/nfcxx-cache/nfcxx-bash`, `tests/nfcxx-cuda-device/nfcxx-bash`)
    are read by suites; some suites extract functions from them with `sed` (for example `tests/driver-ensure-tool`,
    `tests/driver-abspath`, `tests/driver-setup-rest`, `tests/driver-setup-stage`). Each suite must be moved to a pinned copy or
    to the Ruby code before its oracle is deleted.

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
- **B3: the setup stage.** Done for the planning, and the body evals the result (item 3 above). The refusals are #1356. The
  backend choice, the stage after the emit-C route, the sanitizer check, the `pb_flags` tail, the backend environment, the trace
  unit and the rest are planned in Ruby (the last four in c325d76cd). The body keeps its bash for a run with no driver state.
- **B4: the CUDA, `.cpp2` and module stages.** Refusals done (#1363). `cu_prepare` and `cpp2_prepare` make their copies and
  translations in Ruby (`scripts/nfcxx-cu-cpp2-prepare.rb`), and the module block is planned in Ruby (item 2). The body keeps
  the two functions as their callers (item 4).
- **B5: the cache.** Configuration refusal done (#1369). The lookup planner is done (#1432). The lookup, the hit, the store, the
  `--cache-log` line and the remote tier run in Ruby (`scripts/nfcxx-cache-check.rb` and `scripts/nfcxx-cache-io.rb`). The body
  calls `cache_check` and `cache_store` (item 5 above).
- **B6: traps and temporary directories.** The Ruby driver owns the temporary root and its four owned directories (#1499,
  #1505), and the leak fix is merged (#1364). The eccp cleanup skips the directory the driver owns (#1519). The body still makes
  `eccp_dir` and its fallback directories for a run without the driver (item 8 above).
- **B7: the second pass.** The second-pass helper is merged (#1372), and its gate is planned by `nfcxx-second-pass.rb plan`
  (#1517). The driver rewrites the body's second-run line, so the live second run is Ruby (item 9). The gate is still in the body.
- **B8: the switch. Done (#1402).** `./nfcxx` is a shim (`"${RUBY:-ruby}" "$(dirname "$0")/scripts/nfcxx.rb" "$@"`). The
  Ruby driver is the entry point, and the `NFCXX_RUBY_DRIVER` gate is gone. The operational bash body is
  `tests/driver-body/nfcxx-bash` (frozen; `scripts/nfcxx.rb` runs it as its oracle). The cache key hashes
  `tests/driver-body/nfcxx-bash` and every file under `scripts/` (`scripts/nfcxx-cache.rb`), not `./nfcxx`.
  `tests/driver-body/run.sh` no longer diffs the body against `./nfcxx` (that text is now a shim). Suites that read `./nfcxx`
  text use a pinned copy of the pre-switch file (`pinned-*.txt`, taken at 25005e00d).

## Risks

- **Behaviour in failures.** Every bash `|| exit $?` must keep its status. The status chain (section 7 of
  driver-state-design.md) becomes `ensure` plus `exit`.
- **Process startup.** Ruby is already started several times per compile; moving the whole body into one Ruby process
  reduces that. Check the timing on tests/nfcxx-live before and after.
- **macOS.** The driver runs on macOS (Path B probes); the Ruby driver must not assume GNU tools (`realpath -m`, `date %N`).
- **CI.** The bc2cpp scope check (tests/ci/scope_check.rb) must list the new Ruby files as plain `.rb` paths in
  .github/workflows/ci.yml.
