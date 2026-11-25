#!/usr/bin/env bash
# MicroPython .mpy reader (tools/mpy): every corpus module compiled by mpy-cross must load, with every function's prelude
# and every instruction decoded (the reader rejects trailing bytes and an instruction that runs past the end).
#
#   MPY_CROSS=/path/to/mpy-cross tests/mpy/reader_run.sh
# Exit 77 (skip) when MPY_CROSS is not set.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=${TMPDIR:-/tmp}/mpy-reader.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${MPY_CROSS:-}" ] || [ ! -x "$MPY_CROSS" ]; then
  echo "mpy-reader: skipped (set MPY_CROSS to a MicroPython mpy-cross)"
  exit 77
fi
c++ -std=c++17 -Wall -Wextra -o "$work/dump" "$root/tools/mpy/mpy_reader.cpp" "$root/tools/mpy/mpy_dump.cpp" || exit 1
fail=0
n=0
for src in "$root"/tests/mpy/corpus/*.py; do
  base=$(basename "$src" .py)
  "$MPY_CROSS" -o "$work/$base.mpy" "$src" || { echo "FAIL $base: mpy-cross refused the source"; fail=1; continue; }
  if ! "$work/dump" -i "$work/$base.mpy" > "$work/$base.listing" 2> "$work/$base.err"; then
    echo "FAIL $base: $(cat "$work/$base.err")"
    fail=1
    continue
  fi
  n=$((n + 1))
done
if [ "$fail" -ne 0 ]; then
  echo "mpy-reader: FAILED"
  exit 1
fi
echo "mpy-reader: $n modules load, and every function's prelude and instructions decode"
