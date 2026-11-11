#!/usr/bin/env python3
"""Stage compact logs/results and job metadata, even after a failed test step."""
from collections import Counter
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
target = root / 'build/nightly-artifact'
target.mkdir(parents=True, exist_ok=True)
metadata = {key: os.environ.get(key) for key in (
    'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'RUNNER_OS', 'RUNNER_ARCH',
    'ImageOS', 'ImageVersion', 'SUITE_JOBS', 'SURVEY_JOBS', 'SURVEY_TIMEOUT',
    'FEATURE_ROUTES', 'SURVEY_ROUTES', 'UPSTREAM_ROUTES', 'EDG_TEST_TIMEOUT')}
metadata['submodules'] = subprocess.check_output(['git', 'submodule', 'status'], text=True).strip()
(target / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
for name in ('git-snapshots.tsv', 'snapshots.tsv', 'edg-c.json', 'reviewed.tsv', 'reviewed-libraries.tsv'):
    shutil.copy2(root / 'tests/upstream' / name, target / name)
summary = ['## Upstream suite results', '',
           'Native compatibility and compile surveys are observations, not all-pass conformance gates. '
           'Strict feature/runtime checks and infrastructure errors still fail their steps.', '',
           '| Result | Outcomes |', '| --- | --- |']
roots = [root / 'build/nightly', root / 'build/testsuite-snapshots/microsoft-stl-host-survey',
         root / '3rd/edg/tests/runs']
suffixes = {'.json', '.tsv', '.txt', '.log', '.sum', '.elog', '.elist', '.err', '.out', '.patch'}
for source_root in roots:
    if not source_root.exists():
        continue
    for source in source_root.rglob('*'):
        if source.is_symlink() or not source.is_file():
            continue
        if source.suffix not in suffixes and source.name not in ('started', 'completed', 'harness.exit'):
            continue
        relative = source.relative_to(root)
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        label = str(relative).replace('|', '\\|')
        if source.name == 'results.tsv':
            with source.open() as stream:
                rows = list(csv.DictReader(stream, delimiter='\t'))
            if rows and 'status' in rows[0]:
                counts = Counter((r.get('route', 'host'), r['status']) for r in rows)
                summary.append('| ' + label + ' | ' + '; '.join(f'{route}/{status}: {n}' for (route, status), n in sorted(counts.items())) + ' |')
        elif source.name == 'summary.json':
            data = json.loads(source.read_text())
            summary.append('| ' + label + ' | ' + '; '.join(f'{k}: {v}' for k, v in data['outcomes'].items()) + ' |')
        elif source.name in ('regressions.elist', 'changes.elist'):
            summary.append(f'| {label} | {len(source.read_text().splitlines())} entries (native EDG comparison) |')
text = '\n'.join(summary) + '\n'
(target / 'summary.md').write_text(text)
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
        stream.write(text)
print(text)
