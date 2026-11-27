#!/usr/bin/env bash
# Tests that allocations made inside libc are counted under --profile, in the site of the call that makes them
# (docs/notes/profiler.md), for a dynamic link (malloc and friends defined by nfcxx_alloc.c) and a -static link (--wrap,
# nfcxx_alloc_wrap.c). tests/prof/libc.c calls fopen and fprintf (libc mallocs the FILE and its buffer), strdup eight
# times, and alloc_some twice (ten 100-byte allocations each). The profile must count libc's allocations in the run's
# totals and in main's row (the site of the innermost open call), and alloc_some's row must have exactly its own 20.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any"
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/prof2sql.c -lsqlite3 -o "$out/prof2sql"
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/libc_check.c -lsqlite3 -o "$out/libc_check"
for variant in dynamic static; do
  flags=""
  [ "$variant" = static ] && flags="-static"
  ./nfcxx --profile $flags tests/prof/libc.c -o "$out/libc_$variant" > "$out/libc_$variant.build.log" 2>&1
  tmpf=$(mktemp "$out/libc-file.XXXXXX")
  rm -f "$out/libc_$variant.prof"
  NFCXX_PROFILE="$PWD/$out/libc_$variant.prof" "$out/libc_$variant" "$tmpf" | grep -q "^libc$"
  rm -f "$tmpf"
  names=alloc_some # a static link has no symbol names (dladdr), so only the dynamic profile names its function
  [ "$variant" = static ] && names=
  "$out/check_any" "$out/libc_$variant.prof" $names | grep -q "threads=1"
  rm -f "$out/libc_$variant.db"
  "$out/prof2sql" "$out/libc_$variant.prof" "$out/libc_$variant.db"
  echo "== $variant"
  "$out/libc_check" "$out/libc_$variant.db"
done
echo "PASS tests/prof libc"
