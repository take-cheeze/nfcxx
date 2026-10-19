#!/usr/bin/env bash
# Materialize one pinned Git suite without compiler builds or network during tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
suite=${1:?usage: setup-git.sh SUITE}
row=$(awk -F '\t' -v name="$suite" 'NR>1 && $1==name { print }' tests/upstream/git-snapshots.tsv)
[ -n "$row" ] || { echo "unknown suite: $suite" >&2; exit 1; }
IFS=$'\t' read -r name url pin paths <<< "$row"
out=$PWD/build/testsuite-snapshots/$name
mkdir -p "$out"
if [ ! -d "$out/.git" ]; then
  git -C "$out" init -q
  git -C "$out" remote add origin "$url"
fi
[ "$(git -C "$out" remote get-url origin)" = "$url" ] || exit 1
if git -C "$out" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$out" diff --quiet HEAD || { echo "snapshot has local changes: $out" >&2; exit 1; }
fi
if ! git -C "$out" cat-file -e "$pin^{commit}" 2>/dev/null; then
  git -C "$out" fetch --filter=blob:none --depth 1 origin "$pin"
fi
read -r -a selected <<< "$paths"
git -C "$out" sparse-checkout set "${selected[@]}"
git -C "$out" checkout --detach "$pin"
test "$(git -C "$out" rev-parse HEAD)" = "$pin"
echo "Pinned $name: $out ($pin)"
