#!/usr/bin/env bash
# SQLite as a build product (scripts/setup-sqlite.sh) and lib/sqlcache on top of it: tests/sqlite/cache_test.cpp built with
# nfcxx against build/sqlite/<backend>/libsqlite3.a, once per backend, and run.
#   NFCXX_BACKEND=qbe|gcc   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
unset NFCXX
for be in $backends; do
  lib=build/sqlite/$be/libsqlite3.a
  [ -f "$lib" ] || { NFCXX_BACKEND=$be scripts/setup-sqlite.sh || { echo "FAIL $be: setup-sqlite"; fail=1; continue; }; }
  # Links the bundle the way a program does: -L for its directory, -lsqlite3 for the archive, with its MANIFEST checked.
  grep -q '^name: sqlite$' "build/sqlite/$be/MANIFEST" || { echo "FAIL $be: no MANIFEST in the bundle"; fail=1; continue; }
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx tests/sqlite/cache_test.cpp lib/sqlcache/sqlcache.cpp -Lbuild/sqlite/$be -lsqlite3 -o "$tmp/cache-$be" 2>&1); then
    echo "FAIL $be: compile"; head -10 <<<"$out"; fail=1; continue
  fi
  if got=$("$tmp/cache-$be" 2>&1); then
    echo "ok   $be sqlcache (SQLite $(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' build/sqlite/$be/sqlite3.h))"
  else
    echo "FAIL $be: sqlcache"; head -10 <<<"$got"; fail=1
  fi
done
exit $fail
