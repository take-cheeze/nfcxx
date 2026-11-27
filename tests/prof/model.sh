#!/usr/bin/env bash
# The roofline proxy (tools/prof/model.c, docs/notes/profiler-model.md): a profile of tests/prof/cprog.c taken with the
# machine measurements (NFCXX_PROFILE_BENCH=1) and callgrind instruction counts is imported and modelled. Checks that
# the model reports the machine peak and bandwidth and one bound per site, and that a profile without the measurements
# says so. Needs valgrind (callgrind) and the driver (./nfcxx). Not part of run.sh: it is the modelling test.
set -eu
cd "$(dirname "$0")/../.."
out=build/prof-model
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/prof2sql.c -lsqlite3 -o "$out/prof2sql"
$cc -std=c11 -O2 -Wall -Wextra -Werror tools/prof/model.c -lsqlite3 -o "$out/model"
./nfcxx --profile tests/prof/cprog.c -o "$out/cprog" > "$out/build.log" 2>&1
rm -f "$out/bench.prof" "$out/plain.prof" "$out/cg.out"
NFCXX_PROFILE="$PWD/$out/bench.prof" NFCXX_PROFILE_BENCH=1 "$out/cprog" > /dev/null
NFCXX_PROFILE="$PWD/$out/plain.prof" "$out/cprog" > /dev/null
NFCXX_PROFILE="$PWD/$out/cg.prof" valgrind --tool=callgrind --dump-instr=yes \
  --callgrind-out-file="$out/cg.out" "$out/cprog" > /dev/null 2> "$out/valgrind.log"
rm -f "$out/model.db"
"$out/prof2sql" "$out/bench.prof" "$out/model.db" "$out/cg.out" 2> "$out/import.log"
"$out/model" "$out/model.db" > "$out/bench.model"
cat "$out/bench.model"
grep -q "PROXY roofline" "$out/bench.model"
grep -q "peak .* G instr/s" "$out/bench.model"
grep -Eq "^main +[0-9]+ +[0-9]+ .* (compute|memory)$" "$out/bench.model"
grep -Eq "^\+0x[0-9a-f]+ +[0-9]+ +[0-9]+ .* (compute|memory)$" "$out/bench.model"
# a profile without the measurements says so, rather than inventing a peak
"$out/prof2sql" "$out/plain.prof" "$out/plain.db" > /dev/null 2>&1
"$out/model" "$out/plain.db" | grep -q "no clock or bandwidth"
echo "PASS tests/prof model"
