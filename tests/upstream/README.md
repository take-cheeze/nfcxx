# Local upstream test environment

Pinned local sources cover cppreference, cpprefjp, GCC, Clang, LLVM test-suite,
EDG, libc++, libstdc++, and Microsoft STL. Native GCC/Clang/EDG and Linux
library runs are measured below, alongside nfcxx probes and compile surveys.
A source inventory or successful smoke check does **not** mean the full suite
has passed. General GCC/Clang directive adaptation to nfcxx, the alternate
EDG C++ generator, and native Microsoft STL execution remain incomplete.

```sh
# A consistent system compiler/linker avoids this host's mixed Nix/system tools.
PATH=/usr/bin:/bin:$PATH tests/upstream/setup-all.sh sources
PATH=/usr/bin:/bin:$PATH tests/upstream/setup-all.sh smoke

# Never execute unreviewed documentation examples automatically.
PATH=/usr/bin:/bin:$PATH tests/upstream/survey.sh cppreference language
PATH=/usr/bin:/bin:$PATH tests/upstream/survey.sh cpprefjp language
SURVEY_ROUTES='' PATH=/usr/bin:/bin:$PATH tests/upstream/survey.sh cppreference all
SURVEY_ROUTES='' PATH=/usr/bin:/bin:$PATH tests/upstream/survey.sh cpprefjp all
scripts/mrb tests/upstream/reference-report.rb build/testsuite-snapshots \
  > docs/notes/reference-suite-survey.md
```

Setup downloads sources explicitly; the run/survey scripts work offline once
setup has completed. Snapshots, extracted sources, logs and results stay in
ignored `build/testsuite-snapshots/`. Prerequisites are Git, curl, GNU sha256sum,
tar/xz, rg, a host g++, GNU timeout, Python 3 (for native LLVM/EDG tooling),
CMake/Ninja, installed Clang 21, and Docker. `scripts/mrb` bootstraps mruby.
The smoke setup also builds missing nfcxx route tools using the existing setup
scripts. On another host select a consistent host toolchain instead of copying
this machine's PATH workaround blindly.

## Pinned sources and scope

Git identities and sparse paths live in `git-snapshots.tsv`; the cppreference
URL and SHA-256 live in `snapshots.tsv`. Updates are explicit manifest changes.

| Source | Pin | Installed scope / entry point |
| --- | --- | --- |
| cppreference | HTML book 20250209, SHA-256 checked on every setup | All C++ HTML pages; 3,158 extracted example blocks, including 185 language examples. `setup.sh`, `run-cppreference.sh`, `survey.sh`. |
| cpprefjp | `213f89dfff08e0e07152d165cdd779fe20310cb2` | Language/reference markdown; 6,743 explicitly tagged examples, including 290 language examples. `setup-cpprefjp.sh`, `run-selected.sh`, `survey.sh`. |
| GCC | release 15.2.0, `5115c7e447fc07457443df874bf57840e8316d5f` | g++.dg, g++.old-deja, g++.target, DejaGnu helpers and root licenses. 21,712 C++ source files; `run-selected.sh`. |
| Clang | release 21.1.0, `3623fe661ae35c6c80ac221f14d85be76aa870f1` | Entire clang/test plus matching LLVM lit. `run-clang.sh` runs five original tests using their RUN lines and diagnostic expectations. |
| LLVM test-suite | `86553dfbe141d8246e8ab2662e9898b2a25cdf3a` | SingleSource, MultiSource, CMake/lit helpers. `setup-llvm-test-suite.sh` configures the actual SingleSource harness and verifies hello; `run-selected.sh` exercises three C++ programs through nfcxx. |
| libc++ | LLVM pin above | Shared libc++/libc++abi/libunwind build and native lit suite; `setup-libcxx.sh`, `run-libcxx.sh`. |
| libstdc++ | GCC pin above | Full default installed-library DejaGnu suite; `run-libstdcxx.sh`. |
| Microsoft STL | `b6f01e438b68ee497f9c08313e49d12bb2f0d8e0` | std/tr1 source surveys and reviewed portable probes; native Windows runner prepared but unexecuted. |
| EDG | existing submodule `fd27afcbfa58fbeeed588aed5f8467638a09cf2c` | Entire in-tree suite and recorded expectations; `edg.sh regressions`. |

Counts describe this snapshot. Clang's inventory has 18,119 C/C++/.test files,
including auxiliary inputs; LLVM's inventory has 4,963 C/C++ source files,
including helpers. These are not executable test counts. GCC's directive
inventory marks simple positive candidates separately from cases needing a
full harness; it does not silently ignore unsupported directives.

The cppreference archive is the **unofficial** PeterFeicht fork linked from
[cppreference's archive page](https://www.cppreference.com/Cppreference%3AArchives).
It is newer than that page's official 2019 archive. The local source package
and compiler snapshots retain their upstream licenses. Preserve the downloaded
archive and manifests together for offline reuse.

## How much can the references provide?

The full corpora have been compile-surveyed, not just sampled. See the
[generated measurements](../../docs/notes/reference-suite-survey.md).

- cppreference: **3,006/3,158** compile with host GCC in C++23 mode (95.2%).
- cpprefjp: **5,452/6,743** compile in the survey's selected modes (80.9%).
- Language-only inventories were also compiled on qbe, gcc and Path B.
- Runtime assertions remain deliberately reviewed: ten cppreference examples
  and four cpprefjp examples. Arbitrary extracted code is never auto-executed.

The accepted counts are a pool of candidates, not thousands of proven runtime
or conformance tests. Some examples are fragments, intentionally ill-formed,
use draft features or unavailable libraries, print addresses/type names, or
have undefined/unspecified behavior. Rejection is therefore an observation,
not automatically an nfcxx bug. These references complement GCC/Clang/EDG;
they do not replace systematic negative, diagnostic or per-paper tests.

The HTML extractor decodes entities, removes highlighting tags, normalizes
nonbreaking spaces and adds a newline. Only t-example code is extracted, not
every preformatted fragment on a page. IDs retain paths, full stems (including
sizeof versus sizeof...), and example numbers. Writes are atomic and duplicate
IDs fail. Each t-example contributes its first source block; multi-file or
multi-block examples still need manual assembly before becoming runtime tests.
The cpprefjp extractor selects only `cpp example` / `c++ example`
fences, not API declarations or arbitrary cpp fences. It adds a provenance
header; it does not combine independent fragments or repair examples.

Cppreference material retains its
[CC BY-SA 3.0 / GFDL terms](https://en.cppreference.com/Cppreference%3ACopyrights).
Cpprefjp material retains its
[CC BY 4.0 license](https://github.com/cpprefjp/site/blob/213f89d/LICENSE).
Share source attribution, page identity, snapshot and modification notes with
extracted examples. Extracted third-party sources are not vendored into nfcxx.

## Runners and observations

`survey.sh SUITE language|all` uses `SURVEY_JOBS` (default 8),
`SURVEY_TIMEOUT` (20 seconds) and `SURVEY_ROUTES` (qbe/gcc/pathb). An explicitly
empty route list surveys only the host. The host uses -fsyntax-only; nfcxx
routes produce objects with -c. cppreference uses C++23 throughout; cpprefjp
language pages use their named standard, while library pages use C++23.
Neither is an inference of an example's minimum required standard.
`mode-unavailable` distinguishes an unrecognized dialect flag (e.g. C++29).
The report checks inventory uniqueness and complete per-route coverage before
publishing counts. A smoke preflight catches broken/missing tools first.

The measured 20-second budget produced many Path B timeouts, especially on
C++23 hosted-header examples. Those are budget observations, not support
verdicts; rerun with a larger budget before diagnosing compiler behavior.
The corrected sizeof/sizeof... examples were rerun with 60-second limits.
Surveys preserve actual crashes and rejections for investigation.

`run-cppreference.sh` uses `cppreference-reviewed.tsv`; `run-selected.sh` uses
`reviewed.tsv`. `UPSTREAM_ROUTES`, `UPSTREAM_TIMEOUT`, `UPSTREAM_OUT` and
`HOST_CXX` configure these runners. Host/setup errors fail; measured route
gaps are reported. `UPSTREAM_REQUIRE_PASS=1` turns any such gap into a failing
exit status. GCC's reviewed dg-do run tests use the original exit-zero oracle
(stdout can contain addresses). Selected deterministic LLVM/reference programs
also compare stdout with the same host compiler. Neither runner is a general
DejaGnu/lit translator.

## Native EDG and LLVM harnesses

EDG has **45,459 .sft/.mft entry points**, expanding into option/case variants,
across changes/cwg/edg/imported/modules/reflections/regressions/sandbox/stdlib.
The imported sources account for most of its roughly 3 GB test tree.
See [its testing docs](../../3rd/edg/doc/source/testing.rst) and
[build/test skill](../../3rd/edg/.agents/skills/edg-cpfe-build-test/SKILL.md).
The wrapper uses Docker and never rerecords expectations. EDG pins the image:
`edgcpp/dev-env@sha256:1c1cf78d322b7e310b4d35a114f279221b7725b6f3e28939a5212502f07f7f91`.

`edg.sh FILTER` builds cpfe, prelinker/decoder/muncher and native runtime,
then runs the C-generating x86-64 configuration. It validates the emitted
executed-test/change reports as well as the process exit status. This tests
EDG's frontend/runtime, not nfcxx's qbe/Path B pipeline. The fork's alternate
cpfe-cp target currently fails in folding.c (mangled_typeinfo_string undeclared)
and is explicitly excluded; quick-c-fe alone also omits runtime dependencies.

Clang's native smoke uses the installed Clang 21.1.8 with the pinned 21.1.0
source tests and matching lit. It covers both expected diagnostics and positive
cases. The complete Clang regression corpus and a native full-suite site configuration
are installed. The full run excludes uninstalled GoogleTest Unit binaries;
missing auxiliary tools remain visible as failures. LLVM SingleSource uses its actual CMake/lit configuration,
comparison utilities and reference output. External proprietary benchmark
inputs are not downloaded.

## Verified smoke results and remaining gaps

| Check | Local result |
| --- | --- |
| C++11/C++14 pilot | 51 passes per nfcxx route, plus 51 host passes. |
| cppreference reviewed runtime | qbe/gcc 10 each; Path B 9, one compile rejection. |
| cpprefjp reviewed runtime | Four passes on each route. |
| GCC reviewed runtime | Four passes on each route, honoring dg-do run's exit oracle. |
| LLVM reviewed runtime | qbe/gcc three each; Path B two, one output mismatch. |
| Clang native lit | Five passes, including expected diagnostics. |
| LLVM native CMake/lit | hello passes its upstream reference comparison. |
| EDG native regressions | 19 entry points; 20 passing variants, one expected failing variant and one requirements skip; recorded expectations match. |

Known gaps stay visible: cppreference structured_binding-1 is rejected by Path
B with an undefined SSA temporary; LLVM member-function-pointers produces
incorrect output on Path B. The compile survey also exposes frontend crashes;
see per-case logs before interpreting their cause. EDG's expected failure is
regressions/modules/crash-processing-imported-explicit-specialization/test.mft.cpp;
its requirements skip is the C++-backend-only immediate-pragma-lost.sft.cpp.
Matching an upstream baseline does not mean all tests pass.

Results are under build/testsuite-snapshots, with separate folders per survey
and runner. Manifests, compiler versions, nfcxx commit/dirty patch and logs
accompany survey results. Untracked harness files are not captured by git diff;
commit or archive them alongside the results when preserving a baseline.
Nightly and weekly collection is configured in `upstream-nightly.yml`; see the
[CI tiers and failure policy](../../docs/notes/cpp-test-ci-plan.md).

## Broad native runs

Install local DejaGnu/Expect with `tests/upstream/setup-dejagnu.sh`. These are
checksum-verified extracted packages; no system installation is performed.
Use fresh output directories for each run:

```sh
GCC_SUITE_OUT=build/testsuite-snapshots/gcc-native-next tests/upstream/run-gcc-full.sh
CLANG_SUITE_OUT=build/testsuite-snapshots/clang-native-next tests/upstream/run-clang-full.sh all
tests/upstream/edg.sh all
tests/upstream/survey-gcc.sh
```

The native GCC and Clang runners default to eight workers. EDG uses its pinned
Docker posture and an explicit 120-second per-case timeout (override with
`EDG_TEST_TIMEOUT`). The measured all-tree EDG run predates that timeout fix.
Native suite failures are preserved and make the wrappers fail; they do not
establish nfcxx regressions. The additional GCC survey compiles 2,962 positive
source candidates through the nfcxx routes and needs driver/target review
before becoming a regression gate.

See [broad results](../../docs/notes/upstream-suite-results.md). The parallel
execution window was 13m23s with built tools: EDG 12m13s, GCC 8m41s, Clang
6m46s plus a 12s failure retry, and the nfcxx GCC survey 3m54s. Setup/builds
are additional; these local timings are not Actions runner budgets.

## Standard library suites

The existing LLVM and GCC pins also include libc++/libc++abi/libunwind and
libstdc++-v3. Microsoft STL has its own full commit pin. `setup-all.sh sources`
materializes these sources; native library builds/runs are explicit:

```sh
tests/upstream/setup-dejagnu.sh
tests/upstream/run-libstdcxx.sh
tests/upstream/setup-libcxx.sh
tests/upstream/run-libcxx.sh
python3 tests/upstream/survey-ms-stl.py
tests/upstream/survey-ms-stl-routes.sh
PATH=/usr/bin:/bin:$PATH HOST_CXX=/usr/bin/g++ \
  UPSTREAM_MANIFEST=tests/upstream/reviewed-libraries.tsv \
  UPSTREAM_OUT=build/testsuite-snapshots/library-selected-system \
  tests/upstream/run-selected.sh
python3 tests/upstream/library-results.py > docs/notes/library-suite-results.md
```

Native full runners require fresh output directories (`LIBCXX_SUITE_OUT`,
`LIBSTDCXX_SUITE_OUT`). `SUITE_JOBS` defaults to eight. libc++ builds shared
libc++/libc++abi/libunwind in `libcxx-build-system`, with benchmarks disabled,
then runs its original lit configuration and default latest dialect. Its runner
uses system Python with psutil (`SUITE_PYTHON` overrides it) and a 120-second
per-test budget (`SUITE_TIMEOUT`). It preserves feature-based unsupported
results. Setup also extracts a checksum-verified Ubuntu clang-tidy 21.1.8
package locally, using the existing system LLVM dependencies; its source-side
helper is part of the pinned snapshot. The runner prefers this matching tool
(`CLANG_TIDY_EXE` overrides it). libstdc++ uses the documented installed-library DejaGnu configuration,
including upstream target/diagnostic/exit assertions and native parallel
allocation. Its original per-test timeouts remain in force.

The nine reviewed programs use their original runtime assertions and exit
oracle on all nfcxx routes. libc++ and Microsoft-origin sources here are
compiled against **local libstdc++**, not those vendors' headers/runtime.
The Microsoft host survey checks all single-source `test.cpp` and
`test.compile.pass.cpp` files in std/tr1 in C++23, with a 60-second budget.
The 322 host-accepted sources can then be surveyed on every nfcxx route
with `survey-ms-stl-routes.sh`, retaining separate per-route object outcomes.
It does not execute them, expand env.lst, or translate negative tests.
Acceptance/rejection is a portability observation, not the vendor suite oracle.

Microsoft's native STL suite needs Windows with the compiler/SDK versions
specified by its pinned README. On a prepared x64 MSVC Preview developer shell
with PowerShell 7, use:

```powershell
pwsh -File tests/upstream/run-ms-stl.ps1
```

The prepared script initializes the parent pin's LLVM/Boost gitlinks, builds
with the original x64 preset, then runs std, tr1 and its libc++ tests using
upstream stl-lit. It disables extra ASan configurations (`notags=ASAN`), keeps
remaining matrix flags, and writes JSON. This Windows command has not been
executed locally; clang-cl and Wine alone do not supply its missing MSVC/SDK
prerequisites. See [measured library results](../../docs/notes/library-suite-results.md).

## Scheduled runs

[Upstream nightly](../../.github/workflows/upstream-nightly.yml) runs at 02:23
JST daily after merge to the default branch. Monday JST adds the extended
surveys/full EDG tree. Manual dispatch accepts `extended=true`. No PR or push
trigger runs these broad suites. Native Microsoft STL/extra architectures are
not scheduled yet.

Native GCC/Clang/library jobs collect compatibility observations using
`nightly-native.py`: known test failures remain visible in JSON and job
summaries; missing or broken harness outputs fail the job. Strict feature and
reviewed library runtime checks and EDG expectation changes still fail.
`nightly-self-test.py` covers failure classification. Four workers, per-case
budgets and step/job ceilings bound execution. Artifacts are uploaded on
failure and retained for 14 days. Existing local measured results do not
constitute a hosted-runner baseline.

`DEJAGNU_ROOT=/` selects an installed DejaGnu/Expect in the native GCC/library
runners; the default is still the locally extracted pinned packages.
`CLANG_TIDY_EXE` selects a matching installed tool and skips the optional local
package extraction during libc++ setup. `LLVM_TEST_SUITE_OUT` changes the LLVM
hello smoke build/results directory. `SURVEY_ROUTES` can restrict the
Microsoft-origin object survey to one route for independent weekly jobs.
