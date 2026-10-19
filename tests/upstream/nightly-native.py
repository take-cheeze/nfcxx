#!/usr/bin/env python3
"""Collect native outcomes; expected test failures are observations, broken runs fail."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite', choices=['gcc', 'clang', 'libcxx', 'libstdcxx', 'llvm-test-suite'])
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    result = out / 'results'
    env = dict(os.environ)
    env[{'gcc': 'GCC_SUITE_OUT', 'clang': 'CLANG_SUITE_OUT',
         'libcxx': 'LIBCXX_SUITE_OUT', 'libstdcxx': 'LIBSTDCXX_SUITE_OUT',
         'llvm-test-suite': 'LLVM_TEST_SUITE_OUT'}[args.suite]] = str(result)
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
        raise SystemExit(f'Incomplete native run: {error}')
    summary = {'suite': args.suite, 'policy': 'observational; no reviewed CI baseline yet',
               'native_exit': rc, 'outcomes': counts}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
