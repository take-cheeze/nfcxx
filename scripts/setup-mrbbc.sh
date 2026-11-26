#!/usr/bin/env bash
# Build the mruby RITE -> Path B IR producer used by bc2cpp --backend=mrbbc.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$root/build/mrbbc
src=$root/tools/mrbbc
mkdir -p "$work"
output=$work/mrbbc_lower.$$
trap 'rm -f "$output"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -I"$src" \
  "$src/mrb_rite.cpp" "$src/mrb_lower.cpp" "$src/mrbbc_lower_main.cpp" -o "$output"
mv "$output" "$work/mrbbc_lower"
echo "built: $work/mrbbc_lower"
