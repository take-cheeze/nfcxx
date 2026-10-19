#!/usr/bin/env bash
# Compile-only survey: rejected examples are observations, not failed assertions.
set -euo pipefail
cd "$(dirname "$0")/../.."
suite=${1:?usage: survey.sh cppreference|cpprefjp [language|all]}
scope=${2:-language}
case $suite in cppreference|cpprefjp) ;; *) exit 1 ;; esac
case $scope in language) suffix= ;; all) suffix=-all ;; *) exit 1 ;; esac
inventory=$PWD/build/testsuite-snapshots/$suite$suffix-inventory.tsv
test -f "$inventory"
out=${SURVEY_OUT:-$PWD/build/testsuite-snapshots/$suite-$scope-survey}
routes=${SURVEY_ROUTES-'qbe gcc pathb'}
limit=${SURVEY_TIMEOUT:-20}; jobs=${SURVEY_JOBS:-8}
[[ $jobs =~ ^[1-9][0-9]*$ && $limit =~ ^[1-9][0-9]*$ ]] || exit 1
for route in $routes; do case $route in qbe|gcc|pathb) ;; *) exit 1 ;; esac; done
mkdir -p "$out"; out=$(cd "$out" && pwd)
mkdir "$out/.lock" 2>/dev/null || { echo "survey already running: $out" >&2; exit 1; }
trap 'rm -rf "$out/.lock"' EXIT
mkdir "$out/.lock/tasks"
scripts/mrb tests/upstream/reference-manifest.rb "$suite" "$inventory" > "$out/manifest.tsv"
# Preflight all tools before calling a rejection a reference observation.
printf 'int main() { return 0; }\n' > "$out/.lock/smoke.cpp"
for route in host $routes; do
  compiler=$PWD/nfcxx; flags=("--backend=$route" -c)
  if [ "$route" = host ]; then compiler=${HOST_CXX:-g++}; flags=(-fsyntax-only); fi
  env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 2 "$limit" "$compiler" "${flags[@]}" \
    -std=c++11 "$out/.lock/smoke.cpp" -o "$out/.lock/smoke.o" > "$out/$route-smoke.log" 2>&1
done
n=0
while IFS= read -r row; do
  ((n+=1)); [ "$n" = 1 ] && continue
  printf '%s\n' "$row" > "$out/.lock/tasks/$n"
done < "$out/manifest.tsv"
export SURVEY_ROOT=$PWD
find "$out/.lock/tasks" -type f -print0 | sort -z | \
  xargs -0 -r -P "$jobs" -I '{}' tests/upstream/survey-case.sh '{}' "$out" "$routes" "$limit"
printf 'suite\tid\tpage\tstandard\troute\tstatus\texit\n' > "$out/results.tsv.tmp"
while IFS=$'\t' read -r suite id rest; do
  [ "$suite" = suite ] && continue
  cat "$out/$id/result.tsv" >> "$out/results.tsv.tmp"
done < "$out/manifest.tsv"
scripts/mrb tests/upstream/normalize-survey.rb "$out" "$out/results.tsv.tmp" > "$out/results.tsv.normalized"
mv "$out/results.tsv.normalized" "$out/results.tsv"
rm "$out/results.tsv.tmp"
cp tests/upstream/{git-snapshots,snapshots}.tsv "$out/"
git rev-parse HEAD > "$out/nfcxx.commit"
git diff --binary HEAD > "$out/nfcxx.patch"
"${HOST_CXX:-g++}" --version > "$out/host.txt"
uname -sm >> "$out/host.txt"
echo "Compile-only observations: $out/results.tsv"
if awk -F '\t' 'NR>1 && $6=="infrastructure-error" {bad=1} END {exit !bad}' "$out/results.tsv"; then exit 1; fi
