#!/usr/bin/env python3
"""Report native library harness outcomes and separately labelled source probes."""
import argparse
from collections import Counter
import csv
from datetime import datetime
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--base', type=Path, default=Path('build/testsuite-snapshots'))
parser.add_argument('--libcxx', default='libcxx-native-full')
parser.add_argument('--libstdcxx', default='libstdcxx-native-full')
parser.add_argument('--libcxx-retry', type=Path)
args = parser.parse_args()
base = args.base
results = {}
for suite, folder in (('libcxx', args.libcxx), ('libstdcxx', args.libstdcxx)):
    out = base / folder
    if not (out / 'completed').exists():
        raise SystemExit(f'{suite} run has not completed: {out}')
    if suite == 'libcxx':
        data = json.loads((out / 'results.json').read_text())
        first_counts = Counter(t['code'] for t in data['tests'])
        if args.libcxx_retry:
            retry = json.loads((args.libcxx_retry / 'results.json').read_text())
            indexed = {t['name']: t for t in data['tests']}
            for test in retry['tests']:
                if test['name'] not in indexed or indexed[test['name']]['code'] in ('PASS', 'XFAIL', 'UNSUPPORTED'):
                    raise SystemExit('libc++ retry contains an unexpected test')
                indexed[test['name']] = test
            data['tests'] = list(indexed.values())
            results['libcxx_retry'] = {'outcomes': dict(Counter(t['code'] for t in retry['tests'])),
                                       'first_outcomes': dict(first_counts),
                                       'elapsed_seconds': retry['elapsed'], 'path': str(args.libcxx_retry)}
        counts = Counter(t['code'] for t in data['tests'])
        elapsed = data['elapsed']
    else:
        counts = Counter()
        for line in (out / 'combined.sum').read_text().splitlines():
            match = re.match(r'^(PASS|FAIL|XFAIL|XPASS|UNSUPPORTED|UNRESOLVED|UNTESTED|ERROR):', line)
            if match:
                counts[match[1]] += 1
        elapsed = (datetime.fromisoformat((out / 'completed').read_text().strip()) -
                   datetime.fromisoformat((out / 'started').read_text().strip())).total_seconds()
    results[suite] = {'outcomes': dict(counts), 'elapsed_seconds': elapsed, 'path': str(out)}
    if suite == 'libstdcxx':
        failures = [line for line in (out / 'combined.sum').read_text().splitlines()
                    if line.startswith(('FAIL:', 'UNRESOLVED:', 'ERROR:', 'XPASS:'))]
        results[suite]['failure_groups'] = dict(Counter(line.split()[1].split('/')[0] for line in failures))
        (out / 'unexpected.txt').write_text('\n'.join(failures) + '\n')
    else:
        failures = [t for t in data['tests'] if t['code'] not in ('PASS', 'XFAIL', 'UNSUPPORTED')]
        libcxx_failures = failures
        (out / 'unexpected.tsv').write_text('code\tname\n' + ''.join(f"{t['code']}\t{t['name']}\n" for t in failures))
with (base / 'library-selected-system/results.tsv').open() as stream:
    rows = list(csv.DictReader(stream, delimiter='\t'))
if len(rows) != 27 or len({(r['suite'], r['id'], r['route']) for r in rows}) != 27:
    raise SystemExit('Reviewed library probe matrix incomplete or duplicated')
results['nfcxx_reviewed'] = {suite: {route: dict(Counter(r['status'] for r in rows if r['suite'] == suite and r['route'] == route))
                                    for route in ('qbe', 'gcc', 'pathb')}
                            for suite in ('libcxx', 'libstdcxx', 'microsoft-stl')}
survey = base / 'microsoft-stl-host-survey'
with (survey / 'results.tsv').open() as stream:
    observations = list(csv.DictReader(stream, delimiter='\t'))
scope = json.loads((survey / 'scope.json').read_text())
if len(observations) != scope['sources']:
    raise SystemExit('Microsoft source survey incomplete')
results['microsoft_stl'] = {
    'native': 'NOT RUN: Windows/MSVC Preview/SDK prerequisites unavailable locally',
    'host_syntax_survey': dict(Counter(r['status'] for r in observations)),
    'sources': len(observations),
    'elapsed_seconds': float((survey / 'completed').read_text()) - float((survey / 'started').read_text()),
}
route_survey = base / 'microsoft-stl-route-survey'
with (route_survey / 'results.tsv').open() as stream:
    route_rows = list(csv.DictReader(stream, delimiter='\t'))
accepted = sum(r['status'] == 'accepted' for r in observations)
if len(route_rows) != accepted * 4 or len({(r['id'], r['route']) for r in route_rows}) != len(route_rows):
    raise SystemExit('Microsoft route survey incomplete or duplicated')
results['microsoft_stl']['route_survey'] = {
    route: dict(Counter(r['status'] for r in route_rows if r['route'] == route))
    for route in ('host', 'qbe', 'gcc', 'pathb')}
results['microsoft_stl']['route_survey_elapsed_seconds'] = (
    datetime.fromisoformat((route_survey / 'completed').read_text().strip()) -
    datetime.fromisoformat((route_survey / 'started').read_text().strip())).total_seconds()
with (route_survey / 'unexpected.tsv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=route_rows[0].keys(), delimiter='\t', lineterminator='\n')
    writer.writeheader()
    writer.writerows(r for r in route_rows if r['status'] != 'accepted')
(base / 'library-suite-results.json').write_text(json.dumps(results, indent=2) + '\n')
print('# Standard library suite results\n')
print('Native harness results and nfcxx source probes measure different things. Results below describe one Linux x86-64 configuration, not every supported platform, dialect or ABI.\n')
print('| Native suite | Outcomes | Test duration |')
print('| --- | --- | --- |')
for name in ('libcxx', 'libstdcxx'):
    result = results[name]
    print('| ' + name + ' | ' + '; '.join(f'{k}: {v:,}' for k, v in sorted(result['outcomes'].items())) + f" | {result['elapsed_seconds']:.1f}s |")
print('| Microsoft STL | Not run: Windows compiler/SDK prerequisites unavailable | — |\n')
print('libc++ uses LLVM 21.1.0 source, Clang 21.1.8, shared libc++/libc++abi/libunwind built locally, the original lit configuration, and its default C++26 dialect. Benchmarks are disabled; capability-based exclusions remain explicit UNSUPPORTED results. libstdc++ uses the GCC 15.2.0 snapshot, installed GCC/libstdc++ 15.2.0, and the documented installed-library DejaGnu mode with eight native parallel workers. Its counts are assertions, not unique source files. Native failures need triage before they can become reviewed baselines.\n')
print('The libstdc++ native defaults exclude interactive/performance tests; default and LTO debugger variants can share assertion labels. Failure-group counts (including unresolved checks): ' + '; '.join(f'{k}: {v}' for k, v in sorted(results['libstdcxx']['failure_groups'].items())) + '. Debugger pretty-printer failures are separate from library runtime/compile assertions.\n')
if 'libcxx_retry' in results:
    retry = results['libcxx_retry']
    print('libc++ first-run outcomes: ' + '; '.join(f'{k}: {v}' for k, v in sorted(retry['first_outcomes'].items())) + '. One verification rerun after completing the missing clang-tidy helper and selecting the matching system tool recorded ' + '; '.join(f'{k}: {v}' for k, v in sorted(retry['outcomes'].items())) + f" in {retry['elapsed_seconds']:.1f}s. The table merges verified outcomes; both raw runs remain available.\n")
    if libcxx_failures and all('system_reserved_names.gen.py' in t['name'] for t in libcxx_failures):
        print('Every remaining libc++ failure is in system_reserved_names.gen.py. Its reserved-name poison macro for __unused conflicts with a field in the host glibc pthread headers (bits/struct_mutex.h). This is a host-header/suite compatibility observation, not an nfcxx backend failure.\n')
print('## Reviewed runtime probes through nfcxx\n')
print('Nine unchanged upstream programs retain their assertions/exit oracle: three libc++ sources, two libstdc++ sources, and four Microsoft STL sources. All use the local libstdc++ headers/runtime, including the libc++ and Microsoft-origin probes. This does not test nfcxx against those vendors’ implementations or reproduce their full compiler/flag matrix.\n')
print('| Source suite | qbe | gcc | Path B |')
print('| --- | --- | --- | --- |')
for suite, routes in results['nfcxx_reviewed'].items():
    print('| ' + suite + ' | ' + ' | '.join('; '.join(f'{k}: {v}' for k, v in sorted(routes[r].items())) for r in ('qbe', 'gcc', 'pathb')) + ' |')
print('\n## Microsoft STL portability inventory\n')
print(f"The {len(observations):,} single-source `test.cpp`/`test.compile.pass.cpp` files in std/tr1 were syntax-checked with system GCC 15.2 in C++23: " + '; '.join(f'{k}: {v}' for k, v in sorted(results['microsoft_stl']['host_syntax_survey'].items())) + f". Duration: {results['microsoft_stl']['elapsed_seconds']:.1f}s. No unreviewed program was executed. Rejections include Windows/MSVC-specific helpers, implementation internals, missing matrix defines and newer library features; they are not nfcxx failures. The original env.lst matrix and negative tests are not adapted.\n")
print(f'The {accepted} host-accepted sources were additionally surveyed through every nfcxx route in C++23, producing objects without executing them. These are observations against local libstdc++, not Microsoft implementation results. The host syntax check is repeated for the same manifest.\n')
print('| Compile route | Outcomes |')
print('| --- | --- |')
for route, counts in results['microsoft_stl']['route_survey'].items():
    print('| ' + route + ' | ' + '; '.join(f'{k}: {v}' for k, v in sorted(counts.items())) + ' |')
print(f"\nObject survey duration: {results['microsoft_stl']['route_survey_elapsed_seconds']:.1f}s with eight workers and a 60-second per-invocation limit.\n")
print('The Microsoft snapshot is pinned to b6f01e438b68ee497f9c08313e49d12bb2f0d8e0. Its build requires CMake 4.3.1, MSVC 19.53.36829 or newer and Windows SDK 10.0.28000 or newer; its README also calls for Python 3.15 and Clang tools 22.1.3. The prepared PowerShell runner has not been executed here. See the [pinned project instructions](https://github.com/microsoft/STL/tree/b6f01e438b68ee497f9c08313e49d12bb2f0d8e0#how-to-run-the-tests).\n')
print('## Reproduction and artifacts\n')
for result in (results['libcxx'], results['libstdcxx']):
    print(f"- Native results/logs: `{result['path']}`")
if args.libcxx_retry:
    print(f'- libc++ verification results: `{args.libcxx_retry}`')
print('- nfcxx probes: `build/testsuite-snapshots/library-selected-system`')
print('- Microsoft compile survey: `build/testsuite-snapshots/microsoft-stl-host-survey`')
print('- Microsoft-origin nfcxx object survey: `build/testsuite-snapshots/microsoft-stl-route-survey`')
print('- Machine summary: `build/testsuite-snapshots/library-suite-results.json`\n')
print('The first libc++ launch lacked psutil in the default Python; another launch was stopped after a mixed Nix/system linker failed a trivial runtime preflight. Neither is counted here. The accepted run uses system PATH/Python and a fresh CMake build tree. An initial Microsoft array comparison probe selected C++17; the verified manifest uses the required C++20. Original unsuccessful setup logs remain available.\n')
print('See [commands](../../tests/upstream/README.md) and the [CI tiers](cpp-test-ci-plan.md). Upstream harness guidance: [libc++](https://libcxx.llvm.org/TestingLibcxx.html), [libstdc++](https://gcc.gnu.org/onlinedocs/libstdc++/manual/test.html).')
