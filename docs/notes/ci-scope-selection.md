# CI selection for isolated changes

Recent successful runs showed a median elapsed time of 21m14s for bc2cpp
(five runs) and 24m08s for general CI (four runs). Queueing and test execution
both contribute: in the corrected [PR #888 bc2cpp run](https://github.com/take-cheeze/nfcxx/actions/runs/42964179000),
the last shard waited 11m01s and then ran for 15m42s. Fixture setup had a
50-second median across 15 shards; shared library caches were working.

General CI starts 33–38 jobs in those samples, in addition to the separate
bc2cpp workflow. This change reduces general CI's runner demand for changes
whose execution is covered by the bc2cpp workflow, and for Markdown notes.

`scripts/ci-scope.rb` extends the existing `pathb-changes` job with a `full_ci`
output. Its selection policy is deliberately narrow:

| Change/event | General compiler suites | Path B suites |
| --- | --- | --- |
| PR containing only `bc2cpp/**`, `tests/bc2cpp/**`, or `docs/**/*.md` | Skip | Skip |
| PR containing any other path, including mixed changes | Run | Existing Path B selection |
| Push to main | Run | Existing Path B selection |
| Manual run or missing/empty comparison | Run | Run when comparison is unavailable |

Non-Markdown code/patch files under `docs/` retain general coverage. Workflow
and routing-policy changes also retain it. Deleted paths count; renames report
both names, so moving compiler code into a documentation tree cannot hide it.
Paths are NUL-delimited, preserving spaces and newlines. A failed git comparison
fails the selector instead of authorizing reduced coverage.

The general `build`, `arm-build` and `macos-suites` jobs now wait for this
selection. Their dependent matrices retain normal dependency behavior. On an
isolated PR, only the selector and the required aggregation job execute in the
general CI workflow; the dedicated bc2cpp workflow keeps its existing triggers
and checks. This does not change branch-protection settings.

The required `build-and-test` name remains present on every run. Its gate
requires successful selection with explicit boolean outputs, success from all
selected jobs, and `skipped` from every unselected job. Failures, cancellations,
missing outputs, inconsistent selection and unexpectedly skipped selected jobs
fail the gate. The Path B selection agrees with the original regex on all
5,011 paths tracked at the change's base revision.

Validation: `ruby tests/ci/scope_check.rb` covers isolated and mixed changes,
ordinary and manual events, unknown paths, real git renames with unusual names,
selector CLI output, gate CLI behavior, and missing/failed/cancelled jobs.
The workflow is also checked with actionlint and for dependency cycles.

The expected benefit is less runner work and queue pressure. No new elapsed-time
speedup is claimed before observing hosted runs. General compiler builds now
wait for the existing selector, so its own queue time can affect those builds;
this is the tradeoff for selecting coverage before allocating the matrices.
