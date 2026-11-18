# The eccp call (B5/B6): design

This note plans the last large bash-owned step of the driver body: the call to `eccp` in the one-step build, with
its temporary directory, its trap, its trace span and the link record removals around it. It is a design, not a port.
Nothing here changes `./nfcxx`.

## What the bash does now (nfcxx, the one-step build)

1. `eccp_bin="$edg/eccp"; eccp_out=$out`.
2. If `moves = 1`: `eccp_dir=$(mktemp -d)` and a trap: `trace_finish` when `NFCXX_TMP_OWNED=1` (the Ruby root removes
   the directory), otherwise `eccp_cleanup` (removes the directory and the cu/ctmp directories).
3. `eccp_plan` (Ruby, `scripts/nfcxx-eccp-plan.rb`): sets `eccp_argv`, `eccp_envs`, `eccp_cd`.
4. `compile_clean` and the first `link_records_rm` (Ruby, `scripts/nfcxx-link.rb`).
5. `cache_check` (Ruby lookup; a hit exits 0).
6. `t=$(trace_start)`, then a subshell: `cd "$eccp_cd"`, eval of the eccp environment (Ruby, `nfcxx-eccp-env.rb`),
   `"${eccp_argv[@]}"`; then `trace_end "$t" "eccp (...)" eccp`.
7. The second `link_records_rm`.

The status of step 6 is the status of the driver (`set -e`): a failing eccp ends the driver with its status, and the
trap then runs.

## What the Ruby version must preserve

- **Status and stderr.** eccp's status is the driver's status; its standard error goes to the terminal unchanged.
- **Working directory and environment.** The command runs in `eccp_cd` with exactly the `eccp_envs` exports, in a
  child process; the driver's own environment is not changed.
- **Records.** `compile_clean` runs before the call, `link_records_rm` before and after it, and the second removal
  only when eccp succeeded (set -e).
- **Trace.** One span with the label `eccp (front end, C compile, link)` and the category `eccp`. The bash shim
  (`scripts/trace.sh`) and `scripts/trace.rb` must keep the same records; `NFCXX_TRACE_OWNER` makes the driver the
  owner of the trace file.
- **Cleanup on every exit.** The directory removal in `eccp_cleanup` (or the Ruby root's `ensure`) runs on success,
  failure and signals, as the trap does now. `--keep-intermediates` keeps the directory and the root.
- **Cache order.** `cache_check` runs before eccp and `cache_store` after the link, exactly as now.

## Options for the call itself

- **A. Ruby spawns eccp** (`Process.spawn(env, *argv, chdir:, out:, err:)`, then `Process.wait` and `exit $?`).
  Removes the subshell and the bash trap for this call. Needs the trace span from Ruby (`scripts/trace.rb` open,
  span, close) and a signal path that still runs the cleanup (`ensure`).
- **B. Keep the call in bash, move the plan only.** This is what the driver does today. Smallest change; the
  subshell, the trace span and the trap stay in bash until the switch (B8).

Recommendation: **B first**, then A as part of B8. A is only worth it when the whole driver is Ruby, because the trap
and the trace span are shared with the other stages.

## Tests planned

- Differential, with a stub `eccp` that logs its argv, cwd and environment (as the second-pass test does):
  the bash block verbatim against the Ruby call, for: a plain build, a build with `moves=1`, a failing eccp (status
  and the trace record), `--keep-intermediates`, a cache hit, and `NFCXX_TMP_OWNED=1`.
- The existing suites: tests/nfcxx-link (45), tests/driver-eccp-env, tests/nfcxx-linkargs, tests/nfcxx-ecp-arg,
  tests/nfcxx-cache (21), tests/trace.

## Decisions

1. **Option B now, A with B8.** The call stays in bash until the switch. The plan, the environment and the record
   removals are already Ruby (scripts/nfcxx-eccp-plan.rb, nfcxx-eccp-env.rb, nfcxx-link.rb), so B adds the tests below
   and no new planner.
2. **No trace record on a failing eccp.** This is the current behaviour: the driver runs under `set -euo pipefail`, so
   a failing eccp exits before `trace_end`. The port must write no span on failure either.
   tests/driver-eccp-call/run.sh pins this, along with the status pass-through, stderr, the cwd and the environment,
   against the block copied verbatim from ./nfcxx.

## Tests

- tests/driver-eccp-call/run.sh: the call block verbatim, against a stub eccp (success, failure, tracing off, no cd).
  Cleanup on exit (eccp_cleanup, `--keep-intermediates`, the cache hit) is not covered here; it stays in
  tests/nfcxx-link (45) and tests/nfcxx-cache (21), which need an EDG build.
