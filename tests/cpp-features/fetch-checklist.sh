#!/usr/bin/env bash
# Fetch only on explicit invocation; normal probe runs are offline.
set -euo pipefail
cd "$(dirname "$0")/../.."
pin=213f89dfff08e0e07152d165cdd779fe20310cb2
out=build/cpp-features
mkdir -p "$out"
tmp=$(mktemp -d "$out/fetch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fLSs "https://raw.githubusercontent.com/cpprefjp/site/$pin/implementation-status.md" -o "$tmp/source.md"
scripts/mrb scripts/cpp-feature-checklist.rb "$tmp/source.md" > "$tmp/checklist.tsv"
mv "$tmp/source.md" "$out/implementation-status.md"
mv "$tmp/checklist.tsv" "$out/checklist.tsv"
printf '%s\n' "$pin" > "$out/checklist.commit"
echo "Checklist: $out/checklist.tsv (cpprefjp/site $pin)"
