#!/usr/bin/env bash
# Regenerates tools/pathb-ptx-emit/tables.inc (C++) and the canonical dump of the tables from scripts/pathb-ptx-emit.rb.
# Each constant table is extracted by name (its `NAME = ...` line, through its closing `}` at column 0 when multi-line)
# and run with mruby, so the values are exactly the Ruby values; the C++ literals are dumped from them. The dump of the
# Ruby values is written beside it, and tools/pathb-ptx-emit/check-tables.sh compares the C++ dump with it.
# Usage: tools/pathb-ptx-emit/gen-tables.sh [OUT.inc [DUMP.txt]]
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
mrb=${MRB:-$root/build/mruby-tool/bin/mruby}
out=${1:-$root/tools/pathb-ptx-emit/tables.inc}
dump=${2:-$root/tools/pathb-ptx-emit/tables.dump}
src="$root/scripts/pathb-ptx-emit.rb"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
names="VOID SCALARS DYNSHARED_SYM STRING_PREFIX DEVICE_INTRINSICS WARP_SHUFFLES WARP_VOTES SCALAR_U32 FLOAT_BUILTINS FLOAT_TO_INT_BUILTINS HALF_BUILTINS ATOMICS"
: > "$tmp/defs.rb"
for n in $names; do
  awk -v n="$n" '
    !on && index($0, n " = ") == 1 { on = 1; multi = ($0 ~ /\{$/) }
    on { print }
    on && !multi { exit }
    on && multi && /^}/ { exit }
  ' "$src" >> "$tmp/defs.rb"
done
# Every name must be found exactly once.
for n in $names; do
  c=$(grep -c "^$n = " "$tmp/defs.rb" || true)
  [ "$c" = 1 ] || { echo "gen-tables: $n found $c times in $src" >&2; exit 1; }
done
cat "$root/tools/pathb-ptx-emit/gen.rb" >> "$tmp/defs.rb"
"$mrb" "$tmp/defs.rb" > "$out" 2> "$dump"
