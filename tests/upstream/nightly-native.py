#!/usr/bin/env python3
"""Collect native outcomes; expected test failures are observations, broken runs fail."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SUITES = ('gcc', 'clang', 'libcxx', 'libstdcxx', 'llvm-test-suite')
SHARDED = ('libcxx', 'libstdcxx')
POLICY = 'observational; no reviewed CI baseline yet'
# Directories conformance.exp searches, plus the top-level drivers runtest finds without arguments.
LIBSTDCXX_SUBDIRS = ('std', 'abi', 'backward', 'ext', 'performance', 'tr1', 'tr2', 'decimal',
                     'experimental', 'special_functions')
LIBSTDCXX_DRIVERS = ('libstdc++-abi/abi.exp', 'libstdc++-prettyprinters/prettyprinters.exp',
                     'libstdc++-xmethods/xmethods.exp')


def outcomes(suite, directory, exit_code):
    if exit_code not in (0, 1):
        raise ValueError(f"native harness failed with exit {exit_code}")
    if suite in ('clang', 'libcxx', 'llvm-test-suite'):
        filename = 'smoke-results.json' if suite == 'llvm-test-suite' else 'results.json'
        data = json.loads((directory / filename).read_text())
        tests = data['tests']
        if not tests or len({t['name'] for t in tests}) != len(tests):
            raise ValueError('empty or duplicate lit results')
        counts = Counter(t['code'] for t in tests)
    else:
        counts = Counter(re.findall(r'^(PASS|FAIL|XFAIL|XPASS|UNSUPPORTED|UNRESOLVED|UNTESTED|ERROR):',
                                   (directory / 'combined.sum').read_text(), re.M))
        workers = list(directory.glob('worker-*/harness.exit'))
        if not workers or any(p.read_text().strip() not in ('0', '1') for p in workers):
            raise ValueError('missing or failed DejaGnu workers')
    if not counts or counts.get('ERROR'):
        raise ValueError('missing outcomes or harness ERROR')
    if exit_code == 1 and not any(counts.get(s) for s in ('FAIL', 'XPASS', 'UNRESOLVED', 'TIMEOUT')):
        raise ValueError('nonzero exit without a recorded test failure')
    return dict(sorted(counts.items()))


def parse_shard(text):
    match = re.fullmatch(r'([1-9][0-9]*)/([1-9][0-9]*)', text or '')
    if not match or int(match[1]) > int(match[2]):
        raise ValueError(f'invalid shard {text!r}; expected K/N with 1 <= K <= N')
    return int(match[1]), int(match[2])


def libstdcxx_units(srcdir):
    names = set(LIBSTDCXX_SUBDIRS) | {p.name for p in srcdir.iterdir() if re.match(r'[0-9][0-9]', p.name)}
    units = {}
    for name in sorted(names):
        if (srcdir / name).is_dir():
            units[name] = sum(1 for p in (srcdir / name).rglob('*') if p.suffix in ('.cc', '.c') and p.is_file())
    return units


def assign_units(units, shards):
    # Largest-first greedy split; ties use names and indexes so every runner computes the same plan.
    loads = [0] * shards
    groups = [[] for _ in range(shards)]
    for name, count in sorted(units.items(), key=lambda item: (-item[1], item[0])):
        index = min(range(shards), key=lambda i: (loads[i], i))
        groups[index].append(name)
        loads[index] += count
    return [sorted(group) for group in groups]


def libstdcxx_plan(srcdir, index, shards):
    root = os.path.abspath(srcdir)
    if re.search(r'[][*?{}\\\s=]', root):
        raise ValueError(f'unsafe libstdc++ source path for DejaGnu patterns: {root}')
    if not 1 <= index <= shards:
        raise ValueError(f'shard {index} is outside 1..{shards}')
    source = Path(root)
    for driver in ('libstdc++-dg/conformance.exp',) + LIBSTDCXX_DRIVERS:
        if not (source / driver).is_file():
            raise ValueError(f'missing libstdc++ driver: {driver}')
    units = libstdcxx_units(source)
    selected = assign_units(units, shards)[index - 1]
    if not selected:
        raise ValueError(f'shard {index}/{shards} selects no libstdc++ directories')
    # Drivers run once, in shard 1; the other shards pass only their directory patterns to conformance.exp.
    args = [Path(driver).name for driver in LIBSTDCXX_DRIVERS] if index == 1 else []
    args.append('conformance.exp=' + ' '.join(f'{root}/{name}/*' for name in selected))
    return {'shard': f'{index}/{shards}', 'all_units': sorted(units), 'selected': selected, 'args': args}


def merge_suite(suite, summaries):
    counts = Counter()
    exits = []
    shard_count = None
    seen = set()
    names = set()
    units = None
    selected = set()
    for path in summaries:
        data = json.loads(path.read_text())
        index, shards = parse_shard(data.get('shard'))
        if shard_count not in (None, shards):
            raise ValueError(f'{suite}: mixed shard counts')
        shard_count = shards
        if index in seen:
            raise ValueError(f'{suite}: duplicate shard {index}/{shards}')
        seen.add(index)
        counts.update(data['outcomes'])
        exits.append(data['native_exit'])
        results = path.parent / 'results'
        if (results / 'results.json').exists():
            tests = json.loads((results / 'results.json').read_text())['tests']
            shard_names = {t['name'] for t in tests}
            if shard_names & names:
                raise ValueError(f'{suite}: test selected by more than one shard')
            names |= shard_names
        if (results / 'shard.json').exists():
            plan = json.loads((results / 'shard.json').read_text())
            if units not in (None, plan['all_units']):
                raise ValueError(f'{suite}: shards disagree about libstdc++ directories')
            units = plan['all_units']
            if set(plan['selected']) & selected:
                raise ValueError(f'{suite}: libstdc++ directory selected by more than one shard')
            selected |= set(plan['selected'])
    if seen != set(range(1, (shard_count or 0) + 1)):
        raise ValueError(f'{suite}: missing shards, have {sorted(seen)} of {shard_count}')
    if units is not None and selected != set(units):
        raise ValueError(f'{suite}: shards do not cover every libstdc++ directory')
    return {'suite': suite, 'policy': POLICY, 'shards': shard_count,
            'native_exit': 1 if 1 in exits else 0, 'outcomes': dict(sorted(counts.items()))}


def merge_main(root, out):
    found = {suite: [] for suite in SUITES}
    for path in sorted(root.rglob('summary.json')):
        suite = json.loads(path.read_text()).get('suite')
        if suite in found:
            found[suite].append(path)
    missing = [suite for suite in SUITES if not found[suite]]
    if missing:
        raise SystemExit(f'Incomplete native merge: no summaries for {", ".join(missing)}')
    merged = {}
    try:
        for suite in SUITES:
            merged[suite] = merge_suite(suite, found[suite])
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(f'Incomplete native merge: {error}')
    for suite, summary in merged.items():
        (out / suite).mkdir(parents=True, exist_ok=True)
        (out / suite / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(merged))


def log_tail(path, lines=40):
    try:
        return '\n'.join(path.read_text(errors='replace').splitlines()[-lines:])
    except OSError:
        return '(runner.log unavailable)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite', choices=SUITES)
    parser.add_argument('output', type=Path)
    parser.add_argument('--shard', default='1/1', help='K/N: run shard K of N (libcxx and libstdcxx only)')
    args = parser.parse_args()
    try:
        index, shards = parse_shard(args.shard)
    except ValueError as error:
        parser.error(str(error))
    if shards > 1 and args.suite not in SHARDED:
        parser.error(f'{args.suite} is not sharded')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = out / 'results'
    env = dict(os.environ)
    env[{'gcc': 'GCC_SUITE_OUT', 'clang': 'CLANG_SUITE_OUT',
         'libcxx': 'LIBCXX_SUITE_OUT', 'libstdcxx': 'LIBSTDCXX_SUITE_OUT',
         'llvm-test-suite': 'LLVM_TEST_SUITE_OUT'}[args.suite]] = str(result)
    env['SUITE_SHARD'] = f'{index}/{shards}'
    script = {'gcc': 'run-gcc-full.sh', 'clang': 'run-clang-full.sh',
              'libcxx': 'run-libcxx.sh', 'libstdcxx': 'run-libstdcxx.sh',
              'llvm-test-suite': 'setup-llvm-test-suite.sh'}[args.suite]
    command = ['tests/upstream/' + script]
    (out / 'command.json').write_text(json.dumps(command) + '\n')
    with (out / 'runner.log').open('w') as log:
        rc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    (out / 'exit.txt').write_text(str(rc) + '\n')
    try:
        counts = outcomes(args.suite, result, rc)
    except (ValueError, KeyError, OSError) as error:
        message = f'Incomplete native run: {error}'
        if rc != 0 or not any(result.glob('*')):
            message += f'\n--- last 40 lines of {out / "runner.log"} (exit {rc}) ---\n' + log_tail(out / 'runner.log')
        raise SystemExit(message)
    summary = {'suite': args.suite, 'policy': POLICY, 'shard': f'{index}/{shards}',
               'native_exit': rc, 'outcomes': counts}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    if sys.argv[1:2] == ['merge']:
        # merge ROOT OUT: combine downloaded shard summaries into one outcome set per suite.
        merge_main(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    elif sys.argv[1:2] == ['libstdcxx-plan']:
        # libstdcxx-plan SRCDIR K/N: print the DejaGnu shard plan and runtest arguments as JSON.
        index, shards = parse_shard(sys.argv[3])
        print(json.dumps(libstdcxx_plan(Path(sys.argv[2]), index, shards), indent=2))
    else:
        main()
