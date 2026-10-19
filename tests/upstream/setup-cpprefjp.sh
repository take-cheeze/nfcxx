#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tests/upstream/setup-git.sh cpprefjp
out=$PWD/build/testsuite-snapshots
mkdir -p "$out/cpprefjp-examples"
pages=()
while IFS= read -r path; do pages+=("${path#"$out/cpprefjp/"}"); done \
  < <(rg --files --no-ignore "$out/cpprefjp/lang" "$out/cpprefjp/reference" -g '*.md' | sort)
scripts/mrb tests/upstream/cpprefjp-extract.rb "$out/cpprefjp" "$out/cpprefjp-examples" \
  "${pages[@]}" > "$out/cpprefjp-all-inventory.tsv.tmp"
mv "$out/cpprefjp-all-inventory.tsv.tmp" "$out/cpprefjp-all-inventory.tsv"
awk -F '\t' 'NR==1 || $2 ~ /^lang\//' "$out/cpprefjp-all-inventory.tsv" > "$out/cpprefjp-inventory.tsv"
echo "cpprefjp example inventory: $out/cpprefjp-all-inventory.tsv"
