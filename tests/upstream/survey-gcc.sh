#!/usr/bin/env bash
# Positive GCC subset through nfcxx; compile-only observations, no dg emulation.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; snapshot=$root/build/testsuite-snapshots
out=${SURVEY_OUT:-$snapshot/gcc-positive-survey}
routes=${SURVEY_ROUTES:-'qbe gcc pathb'}
jobs=${SURVEY_JOBS:-8}; limit=${SURVEY_TIMEOUT:-60}
for route in $routes; do case $route in qbe|gcc|pathb) ;; *) exit 1 ;; esac; done
mkdir -p "$out"; out=$(cd "$out" && pwd)
mkdir "$out/.lock" || { echo "already running: $out" >&2; exit 1; }
trap 'rm -rf "$out/.lock"' EXIT
mkdir "$out/.lock/tasks"
scripts/mrb tests/upstream/gcc-positive-manifest.rb "$snapshot" > "$out/manifest.tsv"
n=0
while IFS= read -r row; do
  ((n+=1)); [ "$n" = 1 ] && continue
  printf '%s\n' "$row" > "$out/.lock/tasks/$n"
done < "$out/manifest.tsv"
export SURVEY_ROOT=$root
find "$out/.lock/tasks" -type f -print0 | sort -z | \
  xargs -0 -r -P "$jobs" -I '{}' tests/upstream/survey-case.sh '{}' "$out" "$routes" "$limit"
printf 'suite\tid\tpage\tstandard\troute\tstatus\texit\n' > "$out/results.tsv.tmp"
while IFS=$'\t' read -r suite id rest; do
  [ "$suite" = suite ] && continue
  cat "$out/$id/result.tsv" >> "$out/results.tsv.tmp"
done < "$out/manifest.tsv"
scripts/mrb tests/upstream/normalize-survey.rb "$out" "$out/results.tsv.tmp" > "$out/results.tsv"
git rev-parse HEAD > "$out/nfcxx.commit"
cp tests/upstream/git-snapshots.tsv "$out/"
echo "GCC positive compile observations: $out/results.tsv"
