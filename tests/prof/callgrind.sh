#!/usr/bin/env bash
# Cross-checks the profile of tests/prof/cprog.c against callgrind's instruction counts (docs/notes/profiler.md, "Compute
# counts"; docs/notes/profiler-model.md, "Validation").
#
# This is a separate test and is NOT in the default test run. It needs valgrind, which the other tests in this directory do
# not, and it runs the driver and valgrind on cprog: about one second here, well under the 30 s limit, so it could join the
# default run if valgrind is assumed. Run it on its own with: bash tests/prof/callgrind.sh
#
# It builds cprog with ./nfcxx --profile, runs it under `valgrind --tool=callgrind --dump-instr=yes` with NFCXX_PROFILE set,
# imports the profile with the callgrind file (prof2sql PROFILE DB CALLGRIND_OUT), and runs tests/prof/callgrind_check.py,
# which prints a table of site, profile calls, profile exclusive_ns and callgrind self Ir, and the PASS/FAIL checks.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/prof2sql.c -lsqlite3 -o "$out/prof2sql"
./nfcxx --profile tests/prof/cprog.c -o "$out/cprog_cg" > "$out/cprog_cg.build.log" 2>&1
rm -f "$out/cg.prof" "$out/cg.out" "$out/cg.db"
NFCXX_PROFILE="$PWD/$out/cg.prof" valgrind --tool=callgrind --dump-instr=yes \
  --callgrind-out-file="$PWD/$out/cg.out" "$out/cprog_cg" > "$out/cg.stdout" 2> "$out/cg.valgrind.log"
grep -q "^55$" "$out/cg.stdout"
test -s "$out/cg.out"
"$out/prof2sql" "$out/cg.prof" "$out/cg.db" "$out/cg.out"
python3 tests/prof/callgrind_check.py "$out/cprog_cg" "$out/cg.db" "$out/cg.out"
echo "PASS tests/prof callgrind"
