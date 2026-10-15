#!/usr/bin/env bash
# Checks tools/pathb-ptx-emit/tables.inc and tables.dump against scripts/pathb-ptx-emit.rb: regenerates both into a temp
# directory, fails if the committed tables.inc or tables.dump differ, then builds dump.cpp (the C++ values) and fails if
# its output differs from the Ruby dump.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/tools/pathb-ptx-emit"
cxx=${CXX:-g++}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$here/gen-tables.sh" "$tmp/tables.inc" "$tmp/tables.dump"
diff -u "$here/tables.inc" "$tmp/tables.inc" || { echo "check-tables: tables.inc is stale; run tools/pathb-ptx-emit/gen-tables.sh" >&2; exit 1; }
diff -u "$here/tables.dump" "$tmp/tables.dump" || { echo "check-tables: tables.dump is stale" >&2; exit 1; }
"$cxx" -std=c++17 -Wall -Wextra -Werror -I "$here" -o "$tmp/dump" "$here/dump.cpp"
"$tmp/dump" > "$tmp/cxx.dump"
diff -u "$tmp/tables.dump" "$tmp/cxx.dump" || { echo "check-tables: C++ values differ from the Ruby tables" >&2; exit 1; }
echo "check-tables: $(wc -l < "$tmp/cxx.dump") table entries match the Ruby tables"
