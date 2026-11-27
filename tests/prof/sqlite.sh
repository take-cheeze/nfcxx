#!/usr/bin/env bash
# Persists a profile to SQLite (tools/prof/prof2sql.c, docs/notes/profiler-model.md) and checks the stored rows.
# Uses the cprog program of tests/prof: a profile from the driver's --profile, imported twice; and the allocsites program
# (per-site allocation counts), imported once as the third run.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/prof2sql.c -lsqlite3 -o "$out/prof2sql"
$cc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/dbcheck.c -lsqlite3 -o "$out/dbcheck"
./nfcxx --profile tests/prof/cprog.c -o "$out/cprog_db" > "$out/cprog_db.build.log" 2>&1
NFCXX_PROFILE="$PWD/$out/cprog_db.prof" "$out/cprog_db" > /dev/null
rm -f "$out/prof.db"
"$out/prof2sql" "$out/cprog_db.prof" "$out/prof.db"
"$out/prof2sql" "$out/cprog_db.prof" "$out/prof.db"
./nfcxx --profile tests/prof/allocsites.c -o "$out/allocsites" > "$out/allocsites.build.log" 2>&1
NFCXX_PROFILE="$PWD/$out/allocsites.prof" "$out/allocsites" | grep -q "^10$"
"$out/prof2sql" "$out/allocsites.prof" "$out/prof.db"
"$out/dbcheck" "$out/prof.db"
echo "PASS tests/prof sqlite"
