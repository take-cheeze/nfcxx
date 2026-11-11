# GCC, Clang and EDG: broad local suite runs

Native results use the suites' own harnesses and assertions. They are compiler/package baselines, not nfcxx backend results.
GCC uses installed GCC 15.2.0 and the 15.2.0 tests, eight native DejaGnu workers. Clang uses installed 21.1.8 with pinned 21.1.0 regression tests and lit; uninstalled GoogleTest Unit binaries are excluded.
EDG runs the pinned fork's full tree in its C-generating x86-64 Docker configuration; other configurations, including the currently unbuildable C++ generator, are not claimed.

| Run | Outcomes |
| --- | --- |
| GCC / DejaGnu assertions | FAIL: 493; PASS: 244946; UNRESOLVED: 74; UNSUPPORTED: 2348; XFAIL: 2292 |
| Clang / lit tests | FAIL: 594; PASS: 20838; UNSUPPORTED: 382; XFAIL: 29 |
| EDG / actual variant statuses | ABORT: 93; ABORT(COMPILE): 4; BADC: 4; BADC(COMPILE): 52; CATASTROPHE: 974; CATASTROPHE(COMPILE): 41; FAIL: 4585; FAIL(COMPILE): 549; PASS: 40401 |

GCC produced 24,109 distinct source labels across 8 workers; these include common C/C++ tests. Assertions and test-source counts are different units.
Clang reported 21,843 regression tests. Unsupported tests remain distinct from passes; missing test binaries and snapshot/package differences must be triaged before identifying compiler regressions.
The first Clang run recorded FAIL=625, PASS=20807, UNSUPPORTED=382, XFAIL=29.
One verification rerun of its failures, after completing source-side prerequisites, recorded FAIL=594, PASS=31; the table merges those verified outcomes. Original and rerun JSON/logs are both retained.
EDG's executed list has 45,459 entries, with 42,370 metadata archives; 61 entries differ in recorded output, 9 entries are listed as regressions and changes.elog has 118 lines. Actual failure counts include previously expected failures; changed expectations are not rerecorded.

## Measured duration

The overlapping execution window, including the Clang failure retry, was
13m23s with built tools. GCC took 8m41s, Clang 6m46s plus a 12s retry, EDG
12m13s, and the nfcxx GCC source survey 3m54s. Downloads and builds are extra.

## GCC positive sources through nfcxx

All 2,962 sources in the conservative positive manifest were compile-surveyed. Host checks syntax; nfcxx produces objects. No unreviewed program is executed and no general DejaGnu translation is claimed.

| Route | Accepted | Rejected | Crashed | Timed out | Mode unavailable |
| --- | --- | --- | --- | --- | --- |
| host | 2959 | 3 | 0 | 0 | 0 |
| qbe | 2745 | 203 | 14 | 0 | 0 |
| gcc | 2745 | 203 | 14 | 0 | 0 |
| pathb | 2726 | 232 | 4 | 0 | 0 |

Raw paths for this measurement:

- GCC: `build/testsuite-snapshots/gcc-native-full-run`
- Clang: `build/testsuite-snapshots/clang-native-full`
- EDG: `3rd/edg/tests/runs/2026.10.19-19.46.59`
- nfcxx GCC positives: `build/testsuite-snapshots/gcc-positive-survey`
- Clang verification rerun: `build/testsuite-snapshots/clang-native-retry`

The EDG launcher initially overrode the JSON timeout with zero; its last large C99 case completed naturally in 5m52s. No case was terminated. The wrapper now passes the timeout explicitly.
An edit to the running EDG shell wrapper caused its final shell check to fail after the native harness had completed. The saved native executed list, per-case archives and comparison logs were validated directly for this report; the corrected wrapper subsequently passed a fresh native `regressions` run (19 entry points) with the explicit timeout.
Three GCC positive-survey sources also fail the host check: two require generated PCH headers and one belongs to an AArch64-specific driver. These observations are not nfcxx defects. Remaining source selections still need native-target/driver review before becoming assertions.

See [local commands and scope](../../tests/upstream/README.md) and the [CI plan](cpp-test-ci-plan.md). Native failures and compile-survey observations are retained for investigation; no claim of full conformance follows from these runs.
