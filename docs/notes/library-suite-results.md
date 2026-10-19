# Standard library suite results

Native harness results and nfcxx source probes measure different things. Results below describe one Linux x86-64 configuration, not every supported platform, dialect or ABI.

| Native suite | Outcomes | Test duration |
| --- | --- | --- |
| libcxx | FAIL: 40; PASS: 10,085; UNSUPPORTED: 631; XFAIL: 22 | 996.3s |
| libstdcxx | FAIL: 121; PASS: 19,312; UNRESOLVED: 2; UNSUPPORTED: 695; XFAIL: 131 | 756.0s |
| Microsoft STL | Not run: Windows compiler/SDK prerequisites unavailable | — |

libc++ uses LLVM 21.1.0 source, Clang 21.1.8, shared libc++/libc++abi/libunwind built locally, the original lit configuration, and its default C++26 dialect. Benchmarks are disabled; capability-based exclusions remain explicit UNSUPPORTED results. libstdc++ uses the GCC 15.2.0 snapshot, installed GCC/libstdc++ 15.2.0, and the documented installed-library DejaGnu mode with eight native parallel workers. Its counts are assertions, not unique source files. Native failures need triage before they can become reviewed baselines.

The libstdc++ native defaults exclude interactive/performance tests; default and LTO debugger variants can share assertion labels. Failure-group counts (including unresolved checks): 17_intro: 3; 20_util: 6; 23_containers: 3; 24_iterators: 4; 25_algorithms: 2; abi: 1; backward: 1; experimental: 1; libstdc++-prettyprinters: 98; std: 4. Debugger pretty-printer failures are separate from library runtime/compile assertions.

libc++ first-run outcomes: FAIL: 77; PASS: 10048; UNSUPPORTED: 631; XFAIL: 22. One verification rerun after completing the missing clang-tidy helper and selecting the matching system tool recorded FAIL: 40; PASS: 37 in 48.6s. The table merges verified outcomes; both raw runs remain available.

Every remaining libc++ failure is in system_reserved_names.gen.py. Its reserved-name poison macro for __unused conflicts with a field in the host glibc pthread headers (bits/struct_mutex.h). This is a host-header/suite compatibility observation, not an nfcxx backend failure.

## Reviewed runtime probes through nfcxx

Nine unchanged upstream programs retain their assertions/exit oracle: three libc++ sources, two libstdc++ sources, and four Microsoft STL sources. All use the local libstdc++ headers/runtime, including the libc++ and Microsoft-origin probes. This does not test nfcxx against those vendors’ implementations or reproduce their full compiler/flag matrix.

| Source suite | qbe | gcc | Path B |
| --- | --- | --- | --- |
| libcxx | pass: 3 | pass: 3 | pass: 3 |
| libstdcxx | pass: 2 | pass: 2 | pass: 2 |
| microsoft-stl | pass: 4 | pass: 4 | pass: 4 |

## Microsoft STL portability inventory

The 937 single-source `test.cpp`/`test.compile.pass.cpp` files in std/tr1 were syntax-checked with system GCC 15.2 in C++23: accepted: 322; rejected: 615. Duration: 48.3s. No unreviewed program was executed. Rejections include Windows/MSVC-specific helpers, implementation internals, missing matrix defines and newer library features; they are not nfcxx failures. The original env.lst matrix and negative tests are not adapted.

The 322 host-accepted sources were additionally surveyed through every nfcxx route in C++23, producing objects without executing them. These are observations against local libstdc++, not Microsoft implementation results. The host syntax check is repeated for the same manifest.

| Compile route | Outcomes |
| --- | --- |
| host | accepted: 322 |
| qbe | accepted: 304; crash: 14; rejected: 4 |
| gcc | accepted: 304; crash: 14; rejected: 4 |
| pathb | accepted: 270; rejected: 7; timeout: 45 |

Object survey duration: 840.0s with eight workers and a 60-second per-invocation limit.

The Microsoft snapshot is pinned to b6f01e438b68ee497f9c08313e49d12bb2f0d8e0. Its build requires CMake 4.3.1, MSVC 19.53.36829 or newer and Windows SDK 10.0.28000 or newer; its README also calls for Python 3.15 and Clang tools 22.1.3. The prepared PowerShell runner has not been executed here. See the [pinned project instructions](https://github.com/microsoft/STL/tree/b6f01e438b68ee497f9c08313e49d12bb2f0d8e0#how-to-run-the-tests).

## Reproduction and artifacts

- Native results/logs: `build/testsuite-snapshots/libcxx-native-system`
- Native results/logs: `build/testsuite-snapshots/libstdcxx-native-full`
- libc++ verification results: `build/testsuite-snapshots/libcxx-native-retry`
- nfcxx probes: `build/testsuite-snapshots/library-selected-system`
- Microsoft compile survey: `build/testsuite-snapshots/microsoft-stl-host-survey`
- Microsoft-origin nfcxx object survey: `build/testsuite-snapshots/microsoft-stl-route-survey`
- Machine summary: `build/testsuite-snapshots/library-suite-results.json`

The first libc++ launch lacked psutil in the default Python; another launch was stopped after a mixed Nix/system linker failed a trivial runtime preflight. Neither is counted here. The accepted run uses system PATH/Python and a fresh CMake build tree. An initial Microsoft array comparison probe selected C++17; the verified manifest uses the required C++20. Original unsuccessful setup logs remain available.

See [commands](../../tests/upstream/README.md) and the [CI tiers](cpp-test-ci-plan.md). Upstream harness guidance: [libc++](https://libcxx.llvm.org/TestingLibcxx.html), [libstdc++](https://gcc.gnu.org/onlinedocs/libstdc++/manual/test.html).
