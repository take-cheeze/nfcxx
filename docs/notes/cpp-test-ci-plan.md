# C++ test coverage: local environment and proposed CI tiers

Status: local environment is implemented and exercised; the new scheduled
jobs below are a rollout plan. Existing workflows are not rescheduled here.
Reproduction, pins and measured results are in
[`tests/upstream/README.md`](../../tests/upstream/README.md).

## Every pull request: small, deterministic regression gate

Keep the new coverage gate offline: parser/runner/extractor self-tests and the
51 C++11/C++14 probes on qbe and gcc. These are already wired into `ci.yml`
for the feature pilot, including `tests/upstream/self-test.sh`.
Use `FEATURE_REQUIRE_PASS=1`. Do not download documentation or compiler-suite
snapshots on this path. The pinned compiler build is restored from the
existing toolchain cache. A cache miss still requires a real compiler build;
the time budget below concerns the warm-cache test stage.

Target: under two minutes of added wall time, one Linux job, no matrix across
standards/architectures. Keep Path B probes in its existing path-filtered
workflow for compiler/backend changes; move their complete matrix to nightly
if measurement shows the additional PR job is costly. Documentation-only
changes should not trigger the Path B build.

For a repository-wide lighter PR policy, inventory elapsed times from existing
Actions jobs first. Preserve a small cases/driver/builtins/library smoke gate,
then move poly/uop/large real-world builds to scheduled runs after identifying
which fast regressions must remain on PRs. This plan does not silently remove
existing protection or treat an unrun large suite as passing. Those migrations
should be separate, reviewable workflow changes.

## Nightly: broad compatibility and baseline comparison

Proposed schedule: `23 17 * * *` UTC (02:23 JST the following day), on the
default branch, plus `workflow_dispatch` for a chosen ref. PRs can request a
manual broad run; nightly jobs do not run for each PR update.

| Job | Coverage | Initial failure policy |
| --- | --- | --- |
| nfcxx language matrix | All committed probes, all three routes; extend through C++17–23 as probes are written. | Fail any regression from the reviewed per-route baseline. |
| cppreference and cpprefjp | Reviewed runtime examples plus compile-only language surveys (185 and 290 examples); bounded library shards. Never auto-execute unreviewed examples. | Publish actual results; compare with a reviewed baseline. Keep unsupported dialects and compile budgets explicit. |
| EDG own suite | Native Docker harness, C-generating x86-64 configuration; `regressions`, `cwg`, `changes`, then other native groups as timings permit. | Compare recorded upstream expectations; fail new status/output changes and infrastructure failures. Do not rerecord automatically. |
| GCC language suite pilot | Four reviewed exit-zero programs now run on all routes; grow the selection or implement a full directive adapter. | Preserve original oracles; stdout with addresses is not an exact-output assertion. Unsupported directives require the native harness. |
| Clang and LLVM native harnesses | Original diagnostic smoke tests through lit; LLVM CMake/lit reference-output checks and reviewed nfcxx programs. | Keep native compiler results separate from nfcxx route results. |
| Standard library Linux baselines | Native libc++ lit and installed libstdc++ DejaGnu, separate jobs; nine reviewed source probes on nfcxx routes. | Keep vendor implementation baselines separate from source-origin probes using local libstdc++; triage native failures before gating deltas. |
| Existing larger integration suites | Selected poly/uop/real-world checks after the PR-cost audit. | Retain their existing correctness assertions. |

Target: a 30-minute timeout per broad shard initially. Keep route and upstream
group shards independent so one failure does not discard the others' results.
Set small per-case timeouts, bounded parallelism, and a total job timeout.
Use stable test ordering and deterministic shard assignment. If EDG/GCC
inventory exceeds the budget, rotate fixed shards over nightly runs and label
exactly which shard ran; report skipped/unexecuted separately from passing.

The complete local reference surveys are now measured in
[reference-suite-survey.md](reference-suite-survey.md). They contain 3,158
cppreference and 6,743 cpprefjp examples. Host-accepted counts are candidate
selection data, not runtime assertions. Cache host surveys by snapshot and
host-toolchain identity; refresh on snapshot/compiler updates or weekly.
Run the full language-only object surveys nightly and rotate fixed library
shards within the time budget. Do not attempt all ~10,000 examples on all
routes on every PR. The initial 20-second budget yields many Path B timeouts;
measure a less constrained rerun before making these a regression gate.

Do not enable the alternate EDG `cpfe-cp` configuration until its pinned-fork
build failure is fixed. EDG checks the front end and its runtime, whereas
nfcxx's route runs check the actual driver and backend pipeline; both are needed.

## Weekly: expensive or specialized coverage

Run the complete EDG imported groups, a broader GCC suite, draft-standard
experiments and extra targets/configurations after the daily baseline is
stable. Reuse existing emulator/Hexagon workflows where appropriate. Reserve
GPU/device tests for runners with the required hardware; missing devices
produce explicit skips. Pick the weekly window after measuring nightly load.

Measured locally with built tools and eight workers: libstdc++ took 12m36s;
libc++ took 16m36s plus a 49s failed-test verification; the 322-source
Microsoft-origin nfcxx object survey took 14m, and its preceding 937-source
host survey took 48s. These fit the initial per-job budget locally, but do
not predict smaller Actions runner times. The Linux baselines retain 40
libc++ failures and 121 libstdc++ failures plus two unresolved checks; triage
these rather than enabling an all-pass scheduled gate. All 27 reviewed
library runtime cells pass. Keep object acceptance distinct from runtime
assertions; the broader Microsoft-origin survey contains crashes/timeouts.

Microsoft STL needs a separate Windows job. The pinned snapshot currently
requires CMake 4.3.1, MSVC Preview 19.53.36829+, SDK 10.0.28000+, Python
3.15+ and Clang tools 22.1.3. Do not assume the hosted `windows-latest` image
contains these; first exercise `tests/upstream/run-ms-stl.ps1` on an image
with those exact dependencies. Begin with a manual/weekly x64 run, upload
stl-lit JSON/logs, then schedule nightly once costs and baselines are known.
Keep ASan and additional architectures weekly. Portable Microsoft-origin
source probes on Linux are useful nfcxx checks, but do not replace this native
Windows matrix. Cache the 937-source host syntax survey by snapshot/toolchain;
run the 322 host-accepted object candidates on nightly route shards, with
explicit per-case budgets and no unreviewed runtime execution. See [library results](library-suite-results.md).

## Snapshot and result handling

- Pin source archives by URL + SHA-256; Git suites by full commit. Pin EDG's
  container digest through the submodule. Snapshot refreshes are dedicated PRs
  showing inventory additions/removals and result changes.
- Download only in setup jobs; store validated snapshots in the Actions cache
  under keys derived from the committed manifest. Use durable release/object
  storage for long-lived snapshots; cache eviction must not lose the only copy.
- Build compiler tools once, reuse existing toolchain caches, and key EDG's
  separate debug build on submodule + container + build configuration. Include
  repository path/runner platform where cached files embed absolute paths.
- Upload results with `if: always()`: TSV/JSON summaries, logs for failures,
  source/selection manifest, compiler commit and dirty patch, host versions,
  flags, target, and skip reasons. Retain at least 14 nightly runs initially.
- Compare against the last reviewed baseline for the **same** source snapshot,
  runner/target and route. Separate source refreshes, compiler changes and
  harness changes. A fresh snapshot without a baseline is a first measurement.
- Gate on newly failing tests, output mismatches, crashes/timeouts and
  infrastructure errors. Show improvements and stale expected failures too.
  Network/setup errors fail the nightly job, not thousands of individual tests.

GCC's general adapter must honor test actions, options, target/effective-target checks,
negative tests and extra sources. Unknown directives need explicit unsupported
results. The GCC inventory now distinguishes simple positive candidates from
cases needing a native harness. Full native GCC/Clang/EDG runs are now measured in
[upstream-suite-results.md](upstream-suite-results.md). Native failures require
triage and nfcxx diagnostic adaptation still requires explicit feature/tool
support. The warm local parallel window was 13m23s (EDG 12m13s, GCC 8m41s,
Clang 6m46s plus a 12s retry); measure setup and execution again on Actions.
These full native baselines can run nightly within the proposed initial
30-minute shard budget; keep extra configurations and targets weekly.

## Rollout order

1. **Done locally:** pinned sources for all nine candidate suites, available
   native harnesses and reviewed smoke entry points,
   full reference inventories and host compile surveys, and complete
   language-only surveys on the three routes. Reviewed runtime manifests,
   native Clang/LLVM harnesses and EDG expectations are exercised. Extraction,
   ID-collision and unavailable-mode checks pass.
2. Review the measured results and failure logs before adopting baselines:
   cppreference is 10/10 on qbe and gcc, 9/10 on Path B; the EDG regression
   smoke matches recorded expectations, while the full tree identifies nine
   regressed entries. Native GCC/Clang and library failures, plus nfcxx
   crashes/timeouts, remain visible in the linked reports.
3. **PR self-tests wired:** the small upstream extraction self-test shares the
   feature-probe job. Next introduce a manual broad workflow using these exact
   pins and upload reports.
4. Implement explicit baseline comparison and GCC directive handling. Measure
   cold/warm setup and test costs on the actual Actions runner.
5. Enable the nightly schedule after the manual workflow is repeatable; split
   or rotate suites to stay within the budget. Migrate existing heavy PR jobs
   in separate changes based on measured costs.
