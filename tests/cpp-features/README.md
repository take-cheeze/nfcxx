# C++ language coverage probes

The first milestone of [the plan](../../docs/notes/cpp-feature-coverage-plan.md):
41 C++11 rows and 10 C++14 rows from cpprefjp/site at
`213f89dfff08e0e07152d165cdd779fe20310cb2`. These are 51 feature rows,
not 51 distinct papers. Filenames retain standard, paper and page/anchor so
multiple rows for the same paper remain separate. Probes are independently
written; upstream examples are not copied.

Build with `scripts/setup-edg.sh`, `scripts/setup-qbe.sh` and
`scripts/setup-pathb.sh`. Scripts use the repository's mruby interpreter
(`scripts/mrb`, bootstrapped on demand). GNU `timeout` is required. Then run:

```sh
tests/cpp-features/self-test.sh
tests/cpp-features/fetch-checklist.sh
tests/cpp-features/run.sh
scripts/mrb scripts/cpp-feature-report.rb \
  build/cpp-features/checklist.tsv build/cpp-features/results/results.tsv \
  > docs/notes/cpp-feature-matrix.md
```

Only the explicit fetch needs network access. The parser also accepts a local
`implementation-status.md`; source text and parsed TSV stay under ignored
`build/`. The upstream license is CC BY 4.0; the generated matrix attributes
its version cells and links the source and license. Vendor status pages have
not been independently cross-checked.

`// STD:` selects the feature's standard mode, `// PAPER:` records the paper and
`// EXPECT:` is the expected process exit code (0–255), following `tests/run.sh`.
These are positive acceptance and behavior checks, not full paper conformance
or required diagnostics. For example, `alignas` checks a global's alignment,
not the known Path A qbe limitation on aligned locals. The static-local test
checks two callers and one construction; one run cannot prove thread safety.

The default routes are `qbe gcc pathb`. `FEATURE_ROUTES="qbe gcc"` selects a
subset; `FEATURE_ROUTES=host HOST_CXX=g++` validates against a host compiler.
`FEATURE_CXX` replaces the nfcxx executable, `FEATURE_TIMEOUT` sets the timeout
in seconds (default 60), and `FEATURE_OUT` changes the results directory.
A lock prevents simultaneous runs in one directory. `FEATURE_REQUIRE_PASS=1`
fails on any non-pass result (used in CI); otherwise gaps are observational
data and only infrastructure/metadata errors fail.

Each route first compiles and runs a trivial smoke program. Missing builds
or a broken host linker fail the run, rather than reporting false gaps.
Results are TSV, with a log directory per probe and route. Statuses are:

| Status | Meaning |
| --- | --- |
| `pass` | Compiled and returned the expected exit code. |
| `wrong-result` | Ran and returned another exit code. |
| `frontend-rejected` | Both the route and Path A `--emit-c` reject it. |
| `route-rejected` | Route fails but Path A `--emit-c` succeeds; inspect logs for backend, linker, or Path B front-end differences. |
| `host-rejected` | Host comparison compiler rejects it. |
| `compile-crash`, `frontend-crash`, `run-crash` | Exit status greater than 128 (signal convention). |
| `compile-timeout`, `frontend-timeout`, `run-timeout` | GNU timeout's 124 or forced-kill 137. |

A separate Path A front-end pass cannot prove that a failure is in Path B's
backend. Logs retain the evidence for manual review. Investigate signals and
infrastructure failures before updating the published matrix.

The parser covers all 246 rows (41/10/40/58/34/44/19 for C++11/14/17/20/23/26/29).
C++17 onward, vendor cross-checks and next-mode reruns for upstream partial
support remain future milestones. Draft rows are inventory, not support claims.

The pilot matrix was measured on Linux x86-64, with system GCC 15.2.0 and the
compiler/submodule revisions of PR #491 (`93d33e4`). A Nix shell on this host
also exposes a separate linker and runtime; `PATH=/usr/bin:/bin:$PATH` was
used for building and running so the system toolchain stayed consistent.
