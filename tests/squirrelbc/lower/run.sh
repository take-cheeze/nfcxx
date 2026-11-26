#!/usr/bin/env bash
# Squirrel 3.2 bytecode -> Path B IR (tools/squirrelbc/sq_lower.cpp), end to end, for the lowered subset.
#
# Each program is compiled by the reference compiler (`sq -c`, default options), lowered (sq_lower), emitted to QBE IL by
# scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb), assembled by build/qbe/qbe, linked with the runtime in
# tests/squirrelbc/runtime, and run. Three kinds of program:
#   lower/*.nut        the printed result (one line) and the exit status (0) must equal the reference's (sqref).
#   lower/rterr/*.nut  a runtime error: the message line and the exit status (1) must equal the reference's.
#   lower/err/*.nut    refused: sq_lower must exit 3 with "refused:" on stderr and nothing on stdout. An opcode outside
#                      the subset (a call, a table, a string or float literal, a closure, a bitwise operator, ...).
#   lower/refused/*.nut refused at run time with a named message (`// expect:` line 1): the status 1 and that line are
#                      checked; the reference is not run, its result is not the same on every run.
# The reference is the reference VM through tests/squirrelbc/oracle/sqref.c, built from the same tree as `sq`.
# Also lowered: a synthetic stream with DMOVE and DLOAD, which the default compiler does not emit (synth.rb).
#
#   SQ_BUILD=/path/to/squirrel/build SQ_SRC=/path/to/squirrel tests/squirrelbc/lower/run.sh
#
# Exit 77 (skip) when SQ_BUILD (bin/sq, lib/libsquirrel_static.a) or SQ_SRC is not set.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$root/tests/squirrelbc
src=$root/tools/squirrelbc
work=${TMPDIR:-/tmp}/squirrelbc-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${SQ_BUILD:-}" ] || [ ! -x "$SQ_BUILD/bin/sq" ] || [ -z "${SQ_SRC:-}" ]; then
  echo "squirrelbc-lower: skipped (set SQ_BUILD to a Squirrel 3.2 build and SQ_SRC to its source tree)"
  exit 77
fi
sq=$SQ_BUILD/bin/sq

c++ -std=c++17 -O1 -Wall -Wextra -o "$work/lower" "$src/sq_chunk.cpp" "$src/sq_lower.cpp" "$src/sq_lower_main.cpp" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/sqbcrt.o" "$dir/runtime/sqbcrt.c" || exit 1
cc -std=c99 -Wall -Wextra -c -o "$work/driver.o" "$dir/runtime/driver.c" || exit 1
cc -std=c99 -Wall -Wextra -I"$SQ_SRC/include" -o "$work/sqref" "$dir/oracle/sqref.c" \
  "$SQ_BUILD/lib/libsquirrel_static.a" -lstdc++ -lm || exit 1

# build NAME.cnut: the program's binary in $work/NAME, or a failure message on stdout (status 1).
build() {
  local cnut=$1 base=$2
  "$work/lower" "$cnut" > "$work/$base.ir" 2> "$work/$base.err" || { echo "lowering refused: $(cat "$work/$base.err")"; return 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  cc -o "$work/$base" "$work/$base.s" "$work/sqbcrt.o" "$work/driver.o" -lm || { echo "link"; return 1; }
}

fail=0
n=0
for nut in "$dir"/lower/*.nut; do
  base=$(basename "$nut" .nut)
  "$sq" -c -o "$work/$base.cnut" "$nut" || { echo "FAIL $base: sq -c refused the source"; fail=1; continue; }
  if ! msg=$(build "$work/$base.cnut" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base"); gs=$?
  want=$("$work/sqref" "$nut"); ws=$?
  n=$((n + 1))
  if [ "$got" != "$want" ] || [ "$gs" -ne "$ws" ]; then
    echo "FAIL $base: got [$got] (status $gs), the reference gives [$want] (status $ws)"
    fail=1
  fi
done

nr=0
for nut in "$dir"/lower/rterr/*.nut; do
  base=rterr_$(basename "$nut" .nut)
  "$sq" -c -o "$work/$base.cnut" "$nut" || { echo "FAIL $base: sq -c refused the source"; fail=1; continue; }
  if ! msg=$(build "$work/$base.cnut" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base"); gs=$?
  want=$("$work/sqref" "$nut"); ws=$?
  nr=$((nr + 1))
  if [ "$got" != "$want" ] || [ "$gs" -ne "$ws" ]; then
    echo "FAIL $base: got [$got] (status $gs), the reference gives [$want] (status $ws)"
    fail=1
  fi
done

ne=0
for nut in "$dir"/lower/err/*.nut; do
  base=err_$(basename "$nut" .nut)
  "$sq" -c -o "$work/$base.cnut" "$nut" || { echo "FAIL $base: sq -c refused the source"; fail=1; continue; }
  "$work/lower" "$work/$base.cnut" > "$work/$base.ir" 2> "$work/$base.err"; status=$?
  ne=$((ne + 1))
  if [ "$status" -ne 3 ] || ! grep -q '^refused: ' "$work/$base.err" || [ -s "$work/$base.ir" ]; then
    echo "FAIL $base: expected a refusal (exit 3), got exit $status: $(cat "$work/$base.err")"
    fail=1
  fi
done

# lower/refused/*.nut: lowered, then refused at run time with a named message, where the reference's result is not the
# same on every run (it prints an address). The first line `// expect: TEXT` gives the message: our output's line must be
# `error: TEXT` and the status 1. The reference is not run.
nf=0
for nut in "$dir"/lower/refused/*.nut; do
  base=refused_$(basename "$nut" .nut)
  want="error: $(sed -n '1s#^// expect: ##p' "$nut")"
  "$sq" -c -o "$work/$base.cnut" "$nut" || { echo "FAIL $base: sq -c refused the source"; fail=1; continue; }
  if ! msg=$(build "$work/$base.cnut" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base"); gs=$?
  nf=$((nf + 1))
  if [ "$gs" -ne 1 ] || [ "$(printf '%s\n' "$got" | tail -n 1)" != "$want" ]; then
    echo "FAIL $base: got [$got] (status $gs), expected last line [$want] with status 1"
    fail=1
  fi
done

# The synthetic stream: its oracle is the reference VM on the same stream (there is no source).
if ! ruby "$dir/lower/synth.rb" "$work/synth.cnut"; then
  echo "FAIL synth: synth.rb did not write the stream"
  fail=1
elif ! msg=$(build "$work/synth.cnut" synth); then
  echo "FAIL synth: $msg"
  fail=1
else
  got=$("$work/synth"); gs=$?
  want=$("$work/sqref" "$work/synth.cnut"); ws=$?
  if [ "$got" != "$want" ] || [ "$gs" -ne "$ws" ] || [ "$got" != "9999999993" ]; then
    echo "FAIL synth: got [$got] (status $gs), the reference gives [$want] (status $ws)"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "squirrelbc-lower: FAILED"
  exit 1
fi
echo "squirrelbc-lower: $n programs match the reference; $nr runtime errors match; $ne programs refused (exit 3); $nf runtime refusals with their named message; synthetic DLOAD/DMOVE/LOADNULLS stream matches"
