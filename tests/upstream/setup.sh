#!/usr/bin/env bash
# Fetch pinned documentation data explicitly; test runs themselves are offline.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$PWD/build/testsuite-snapshots
mkdir -p "$out"
IFS=$'\t' read -r suite version url checksum < <(sed -n '2p' tests/upstream/snapshots.tsv)
archive="$out/html-book-$version.tar.xz"
if [ ! -f "$archive" ]; then
  curl -fLSs "$url" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
mkdir -p "$out/cppreference" "$out/cppreference-examples"
tar -xJf "$archive" -C "$out/cppreference"
pages=()
for path in "$out/cppreference/reference/en/cpp/language/"*.html; do
  pages+=("cpp/language/$(basename "$path")")
done
scripts/mrb tests/upstream/cppreference-extract.rb "$out/cppreference/reference/en" \
  "$out/cppreference-examples" "${pages[@]}" > "$out/cppreference-inventory.tsv.tmp"
mv "$out/cppreference-inventory.tsv.tmp" "$out/cppreference-inventory.tsv"
pages=()
while IFS= read -r path; do
  pages+=("${path#"$out/cppreference/reference/en/"}")
done < <(rg --files --no-ignore "$out/cppreference/reference/en/cpp" -g '*.html' | sort)
scripts/mrb tests/upstream/cppreference-extract.rb "$out/cppreference/reference/en" \
  "$out/cppreference-examples" "${pages[@]}" > "$out/cppreference-all-inventory.tsv.tmp"
mv "$out/cppreference-all-inventory.tsv.tmp" "$out/cppreference-all-inventory.tsv"
git rev-parse HEAD > "$out/nfcxx.commit"
git rev-parse HEAD:3rd/edg > "$out/edg.commit"
cp tests/upstream/snapshots.tsv "$out/snapshots.tsv"
echo "Offline example inventory: $out/cppreference-inventory.tsv"
echo "EDG suite: 3rd/edg/tests (pinned by the submodule; tests/upstream/edg.sh runs it in Docker)"
