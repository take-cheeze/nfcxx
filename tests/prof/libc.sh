#!/usr/bin/env bash
# Tests that allocations made inside libc are counted under --profile, in the site of the call that makes them
# (docs/notes/profiler.md). tests/prof/libc.c calls fopen and fprintf (libc mallocs the FILE and its buffer), strdup eight
# times, and alloc_some twice (ten 100-byte allocations each). The profile must count libc's allocations in the run's totals and in
# main's row (the site of the innermost open call), and alloc_some's row must have exactly its own 20 allocations.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/prof2sql.c -lsqlite3 -o "$out/prof2sql"
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/libc_check.c -lsqlite3 -o "$out/libc_check"
./nfcxx --profile tests/prof/libc.c -o "$out/libc" > "$out/libc.build.log" 2>&1
tmpf=$(mktemp "$out/libc-file.XXXXXX")
rm -f "$out/libc.prof"
NFCXX_PROFILE="$PWD/$out/libc.prof" "$out/libc" "$tmpf" | grep -q "^libc$"
rm -f "$tmpf"
"$out/check_any" "$out/libc.prof" alloc_some | grep -q "threads=1"
rm -f "$out/libc.db"
"$out/prof2sql" "$out/libc.prof" "$out/libc.db"
"$out/libc_check" "$out/libc.db"
echo "PASS tests/prof libc"
