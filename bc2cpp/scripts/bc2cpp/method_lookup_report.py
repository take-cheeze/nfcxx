#!/usr/bin/env python3
"""Summarize process-local lookup surveys against each run's installed table."""
import collections
import csv
import json
from pathlib import Path
import subprocess
import sys

logs, binary, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
files = sorted(path for path in logs.glob('*.lookups.tsv') if path.name != 'baseline.lookups.tsv')
if not files:
    raise SystemExit('no lookup survey files')
entries = {}
transient = collections.Counter()
misses = collections.Counter()
inventories = []
for path in files:
    inventory = set()
    with path.open() as handle:
        for raw in csv.DictReader(handle, delimiter='\t'):
            owner = bytes.fromhex(raw['owner_hex']).decode('utf-8', 'backslashreplace')
            name = bytes.fromhex(raw['name_hex']).decode('utf-8', 'backslashreplace')
            counts = [int(raw[phase]) for phase in ('core', 'gems', 'gameplay')]
            if owner == '<outside-final-table>':
                target = misses if raw['kind'] == 'missing' else transient
                for phase, count in zip(('core', 'gems', 'gameplay'), counts):
                    if count:
                        target[name, phase] += count
                continue
            key = owner, name
            if key in inventory:
                raise SystemExit(f'duplicate owner/name {key} in {path}')
            inventory.add(key)
            entry = entries.setdefault(key, dict(owner=owner, method=name, kind=raw['kind'], address=raw['address'], core=0, gems=0, gameplay=0))
            if (entry['address'], entry['kind']) != (raw['address'], raw['kind']):
                raise SystemExit(f'unstable executable entry {key}')
            for phase, count in zip(('core', 'gems', 'gameplay'), counts):
                entry[phase] += count
    inventories.append(inventory)
if any(inventory != inventories[0] for inventory in inventories):
    raise SystemExit('installed inventory differs between runs')
addresses = {entry['address'] for entry in entries.values() if entry['address'] != '0x0'}
samples = collections.Counter()
for path in files:
    with Path(str(path) + '.stacks').open() as handle:
        for row in csv.DictReader(handle, delimiter='\t'):
            name = bytes.fromhex(row['name_hex']).decode('utf-8', 'backslashreplace')
            frames = tuple(value for value in row['frames'].split(',') if value)
            addresses.update(frames)
            samples[name, int(row['phase']), frames] += int(row['samples'])
addresses = sorted(addresses)
resolved = subprocess.run(['addr2line', '-f', '-C', '-e', str(binary)], input='\n'.join(addresses)+'\n', text=True, capture_output=True, check=True).stdout.splitlines()
if len(resolved) != 2 * len(addresses):
    raise SystemExit('incomplete addr2line output')
locations = {address: (resolved[2*i], resolved[2*i+1]) for i, address in enumerate(addresses)}
for entry in entries.values():
    function, source = locations.get(entry['address'], ('', ''))
    entry.update(function=function, source=source)
    entry['implementation'] = 'undefined' if entry['kind'] == 'undefined' else 'bytecode' if entry['kind'] == 'bytecode' else 'compiled' if '-compiled/' in source else 'native'
    entry['observed'] = bool(entry['core'] + entry['gems'] + entry['gameplay'])
    entry['runtime_observed'] = bool(entry['gameplay'])
ordered = sorted(entries.values(), key=lambda row: (row['owner'], row['method']))
with (output/'entries.tsv').open('w') as handle:
    writer = csv.DictWriter(handle, fieldnames=list(ordered[0]), delimiter='\t')
    writer.writeheader()
    writer.writerows(ordered)
caller_samples = collections.Counter()
for (name, phase, frames), count in samples.items():
    for address in frames:
        function, source = locations[address]
        if ('/tools/bc2cpp/' in source or '-compiled/' in source or '/src/' in source) and not any(skip in source for skip in ('/src/class.c:', '/src/vm.c:')):
            caller_samples[name, phase, function, source] += count
            break
with (output/'sampled-callers.tsv').open('w') as handle:
    writer = csv.writer(handle, delimiter='\t')
    writer.writerow(('method', 'phase', 'samples', 'function', 'source'))
    for (name, phase, function, source), count in caller_samples.most_common():
        writer.writerow((name, ('core', 'gems', 'gameplay')[phase], count, function, source))
vm = collections.Counter()
vm_runs = {}
vm_files = list(logs.glob('*.vm.tsv'))
if len(vm_files) != len(files) + 1:
    raise SystemExit('missing per-run VM counters or startup baseline')
for path in vm_files:
    if path.name == 'baseline.vm.tsv':
        continue
    current = collections.Counter()
    for line in path.read_text().splitlines():
        count, kind, name = line.split('\t', 2)
        vm[kind] += int(count)
        current[kind] += int(count)
    vm_runs[path.name] = current
baseline_vm = collections.Counter()
for line in (logs/'baseline.vm.tsv').read_text().splitlines():
    count, kind, name = line.split('\t', 2)
    baseline_vm[kind] += int(count)
if not sum(baseline_vm.values()):
    raise SystemExit('startup baseline has no VM counter events; check instrumentation')
if any(count - baseline_vm[kind] * len(files) < 0 for kind, count in vm.items()):
    raise SystemExit('VM baseline exceeds a sweep total')
summary = dict(runs=len(files), installed_entries=len(entries), observed_entries=sum(row['observed'] for row in ordered),
               runtime_observed_entries=sum(row['runtime_observed'] for row in ordered),
               unobserved_entries=sum(not row['observed'] for row in ordered),
               implementations=dict(collections.Counter(row['implementation'] for row in ordered)),
               observed_implementations=dict(collections.Counter(row['implementation'] for row in ordered if row['observed'])),
               phase_lookups={phase: sum(row[phase] for row in ordered) for phase in ('core', 'gems', 'gameplay')},
               all_phase_lookups={phase: sum(row[phase] for row in ordered) + sum(count for (name, part), count in transient.items() if part == phase) + sum(count for (name, part), count in misses.items() if part == phase) for phase in ('core', 'gems', 'gameplay')},
               vm_starts_total=dict(vm), vm_starts_baseline=dict(baseline_vm),
               vm_runs_matching_baseline=sum(value == baseline_vm for value in vm_runs.values()),
               vm_starts_beyond_startup={kind: count - baseline_vm[kind] * len(files) for kind, count in vm.items()},
               top_runtime=sorted(ordered, key=lambda row: -row['gameplay'])[:25],
               outside_installed_table=[dict(method=name, phase=phase, count=count) for (name, phase), count in transient.most_common()],
               misses=[dict(method=name, phase=phase, count=count) for (name, phase), count in misses.most_common()])
(output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps({key: value for key, value in summary.items() if key not in ('top_runtime', 'outside_installed_table', 'misses')}, indent=2))
