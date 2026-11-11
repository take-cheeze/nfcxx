#!/bin/sh
# Regenerates the expected output of every testbed program from the real Swift
# compiler (swiftc from the toolchain on PATH). Run this when a program changes;
# the expected files are committed so run.sh does not need swiftc.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for src in "$dir"/programs/*.swift; do
  name=$(basename "$src" .swift)
  swiftc -Onone "$src" -o "$tmp/$name" 2>"$tmp/$name.err" || { cat "$tmp/$name.err"; echo "swiftc failed: $name"; exit 1; }
  "$tmp/$name" > "$dir/programs/$name.expected"
  echo "oracle: $name"
done
