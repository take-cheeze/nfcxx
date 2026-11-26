#!/usr/bin/env bash
# Squirrel 3.2 bytecode reader (tools/squirrelbc/sq_chunk.cpp) against the reference tree.
#
# Every program of corpus/ and of lower/ is compiled to bytecode by the reference compiler (`sq -c`, default options) and:
#   - must load in sq_dump: exit 0, every instruction decoded by name, the stream fully consumed (sq_chunk.cpp refuses
#     any byte left after TAIL, and any truncated record);
#   - must run in the reference VM with the same result as its source (sqref loads the .cnut with sq_readclosure).
# Also checked: the opcode table of sq_dump equals the _OP_ enum of the reference's sqopcodes.h; the dump of lower/ints.nut
# equals the golden tests/squirrelbc/reader/ints.dump; and streams that are malformed (truncated, trailing bytes, a bad
# tag, a bad header size, a bad TAIL) are refused with exit 1.
#
#   SQ_BUILD=/path/to/squirrel/build SQ_SRC=/path/to/squirrel tests/squirrelbc/run.sh
#
# SQ_BUILD holds bin/sq and lib/libsquirrel_static.a (a CMake build of the reference tree); SQ_SRC is the reference
# source tree (include/, squirrel/sqopcodes.h). Exit 77 (skip) when either is not set.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
src=$root/tools/squirrelbc
dir=$root/tests/squirrelbc
work=${TMPDIR:-/tmp}/squirrelbc-reader.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${SQ_BUILD:-}" ] || [ ! -x "$SQ_BUILD/bin/sq" ] || [ -z "${SQ_SRC:-}" ]; then
  echo "squirrelbc-reader: skipped (set SQ_BUILD to a Squirrel 3.2 build and SQ_SRC to its source tree)"
  exit 77
fi
sq=$SQ_BUILD/bin/sq

c++ -std=c++17 -O1 -Wall -Wextra -o "$work/sq_dump" "$src/sq_chunk.cpp" "$src/sq_dump.cpp" || exit 1
cc -std=c99 -Wall -Wextra -I"$SQ_SRC/include" -o "$work/sqref" "$dir/oracle/sqref.c" \
  "$SQ_BUILD/lib/libsquirrel_static.a" -lstdc++ -lm || exit 1

fail=0
n=0

# The opcode table against the reference enum.
"$work/sq_dump" --opcodes > "$work/ops.txt"
sed -n 's/^    \(_OP_[A-Z0-9_]*\)=.*/\1/p' "$SQ_SRC/squirrel/sqopcodes.h" > "$work/ops_ref.txt"
if ! diff -q "$work/ops_ref.txt" "$work/ops.txt" > /dev/null; then
  echo "FAIL opcode table differs from $SQ_SRC/squirrel/sqopcodes.h"
  diff "$work/ops_ref.txt" "$work/ops.txt" | head -10
  fail=1
fi

check_program() {
  local nut=$1 base=$2
  local cnut=$work/$base.cnut
  "$sq" -c -o "$cnut" "$nut" || { echo "FAIL $base: sq -c refused the source"; fail=1; return; }
  n=$((n + 1))
  if ! "$work/sq_dump" "$cnut" > "$work/$base.dump" 2> "$work/$base.err"; then
    echo "FAIL $base: sq_dump refused the stream: $(cat "$work/$base.err")"
    fail=1
    return
  fi
  if grep -q '(null)' "$work/$base.dump"; then
    echo "FAIL $base: an instruction has no name"
    fail=1
  fi
  local want got
  want=$("$work/sqref" "$nut"; echo "status $?")
  got=$("$work/sqref" "$cnut"; echo "status $?")
  if [ "$want" != "$got" ]; then
    echo "FAIL $base: the bytecode runs differently: source [$want] bytecode [$got]"
    fail=1
  fi
}

for nut in "$dir"/corpus/*.nut "$root"/tests/squirrelbc/lower/*.nut; do
  check_program "$nut" "$(basename "$nut" .nut)"
done

# The synthetic stream of lower/synth.rb (DLOAD, DMOVE, LINE, LOADNULLS) must load and be fully consumed too.
if ruby "$dir/lower/synth.rb" "$work/synth.cnut" && "$work/sq_dump" "$work/synth.cnut" > /dev/null; then
  n=$((n + 1))
else
  echo "FAIL synth: lower/synth.rb stream refused by sq_dump"
  fail=1
fi

# Golden dump: one program, every instruction by name.
"$sq" -c -o "$work/ints.cnut" "$dir/lower/ints.nut"
"$work/sq_dump" "$work/ints.cnut" > "$work/ints.dump"
if ! diff -u "$dir/reader/ints.dump" "$work/ints.dump" > "$work/ints.diff"; then
  echo "FAIL golden dump of lower/ints.nut differs:"
  head -20 "$work/ints.diff"
  fail=1
fi

# Malformed streams are refused with exit 1 (and never loaded).
"$sq" -c -o "$work/good.cnut" "$dir/corpus/closures.nut" || { echo "FAIL: sq -c refused the malformed-stream base"; exit 1; }
size=$(wc -c < "$work/good.cnut")
refuse() {
  local f=$1 what=$2
  if "$work/sq_dump" "$f" > /dev/null 2> "$work/refuse.err"; then
    echo "FAIL $what: a malformed stream was loaded"
    fail=1
  elif [ "$?" -ne 1 ]; then
    echo "FAIL $what: wrong status for a malformed stream"
    fail=1
  fi
}
head -c $((size - 1)) "$work/good.cnut" > "$work/trunc.cnut"; refuse "$work/trunc.cnut" "truncated stream"
cp "$work/good.cnut" "$work/trail.cnut"; printf 'x' >> "$work/trail.cnut"; refuse "$work/trail.cnut" "trailing byte"
cp "$work/good.cnut" "$work/tag.cnut"; printf '\000' | dd of="$work/tag.cnut" bs=1 seek=0 conv=notrunc 2>/dev/null
refuse "$work/tag.cnut" "bad tag"
cp "$work/good.cnut" "$work/isize.cnut"; printf '\004' | dd of="$work/isize.cnut" bs=1 seek=10 conv=notrunc 2>/dev/null
refuse "$work/isize.cnut" "SQInteger size 4"
cp "$work/good.cnut" "$work/tail.cnut"; printf 'XXXX' | dd of="$work/tail.cnut" bs=1 seek=$((size - 4)) conv=notrunc 2>/dev/null
refuse "$work/tail.cnut" "corrupt TAIL"

if [ "$fail" -ne 0 ]; then
  echo "squirrelbc-reader: FAILED"
  exit 1
fi
echo "squirrelbc-reader: $n programs load, run like their source, and are fully consumed; opcode table matches sqopcodes.h; malformed streams are refused"
