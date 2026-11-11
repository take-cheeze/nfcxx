#!/usr/bin/env bash
# Host-accepted Microsoft-origin sources; object observations, no execution.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH=/usr/bin:/bin:$PATH
export SURVEY_ROOT=$PWD
base=$PWD/build/testsuite-snapshots
routes=${SURVEY_ROUTES:-'qbe gcc pathb'}
for route in $routes; do case $route in qbe|gcc|pathb) ;; *) exit 1 ;; esac; done
out=${SURVEY_OUT:-$base/microsoft-stl-route-survey}
mkdir -p "$out"; out=$(cd "$out" && pwd)
mkdir "$out/.lock"
trap 'rm -rf "$out/.lock"' EXIT
mkdir "$out/.lock/tasks"
printf 'int main() { return 0; }\n' > "$out/.lock/smoke.cpp"
for route in host $routes; do
  compiler=$PWD/nfcxx; flags=("--backend=$route" -c)
  if [ "$route" = host ]; then compiler=${HOST_CXX:-g++}; flags=(-fsyntax-only); fi
  env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 2 "${SURVEY_TIMEOUT:-60}" "$compiler" "${flags[@]}" \
    -std=c++11 "$out/.lock/smoke.cpp" -o "$out/.lock/smoke.o" > "$out/preflight-$route.log" 2>&1
done
export SURVEY_INCLUDE=$base/microsoft-stl/tests/std/include
python3 - "$base" "$out" <<'PY'
import csv
import hashlib
from pathlib import Path
import sys
base, out = map(Path, sys.argv[1:])
with (base / 'microsoft-stl-host-survey/results.tsv').open() as stream:
    rows = [r for r in csv.DictReader(stream, delimiter='\t') if r['status'] == 'accepted']
with (out / 'manifest.tsv').open('w') as stream:
    writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
    writer.writerow(['suite', 'id', 'page', 'standard', 'source'])
    for index, row in enumerate(rows):
        relative = row['source']
        identifier = 'ms-' + hashlib.sha256(relative.encode()).hexdigest()[:16]
        values = ['microsoft-stl', identifier, relative, 'c++23', str(base / 'microsoft-stl' / relative)]
        writer.writerow(values)
        (out / '.lock/tasks' / str(index)).write_text('\t'.join(values) + '\n')
PY
date -u +%FT%TZ > "$out/started"
find "$out/.lock/tasks" -type f -print0 | sort -z | \
  xargs -0 -r -P "${SURVEY_JOBS:-8}" -I '{}' tests/upstream/survey-case.sh \
    '{}' "$out" "$routes" "${SURVEY_TIMEOUT:-60}"
printf 'suite\tid\tpage\tstandard\troute\tstatus\texit\n' > "$out/results.tsv.tmp"
while IFS=$'\t' read -r suite id rest; do
  [ "$suite" = suite ] && continue
  cat "$out/$id/result.tsv" >> "$out/results.tsv.tmp"
done < "$out/manifest.tsv"
mv "$out/results.tsv.tmp" "$out/results.tsv"
date -u +%FT%TZ > "$out/completed"
cp tests/upstream/git-snapshots.tsv "$out/"
git rev-parse HEAD > "$out/nfcxx.commit"
echo "Microsoft-origin object observations: $out/results.tsv"
if awk -F '\t' 'NR>1 && $6=="infrastructure-error" {bad=1} END {exit !bad}' "$out/results.tsv"; then exit 1; fi
