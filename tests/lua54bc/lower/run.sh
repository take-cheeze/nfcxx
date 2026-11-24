#!/usr/bin/env bash
# Lua 5.4 bytecode -> Path B IR (tools/lua54bc/lua54_lower.cpp), end to end, for the lowered subset.
#
# Each program in this directory is compiled by Lua 5.4.9 (LUA, dump.lua), lowered to IR (lua54_lower), emitted to QBE IL
# by scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb), assembled by QBE, linked with the runtime helpers and the driver
# in tests/lua54bc/runtime, run, and its result compared with `lua`'s. A program that uses an opcode not lowered yet must
# be refused (exit 3), never compiled.
#
#   LUA=/path/to/lua tests/lua54bc/lower/run.sh
# Exit 77 (skip) when LUA is not a 5.4.9 interpreter.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$root/tests/lua54bc
work=${TMPDIR:-/tmp}/lua54bc-lower.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${LUA:-}" ] || ! "$LUA" -v 2>&1 | grep -q '^Lua 5\.4\.9\b'; then
  echo "lua54bc-lower: skipped (set LUA to a Lua 5.4.9 interpreter)"
  exit 77
fi

c++ -std=c++17 -O1 -o "$work/lower" "$root/tools/lua54bc/lua54_chunk.cpp" "$root/tools/lua54bc/lua54_lower.cpp" \
  "$root/tools/lua54bc/lua54_lower_main.cpp" || exit 1
cc -c -o "$work/rt.o" "$dir/runtime/lua54rt.c" || exit 1
cc -c -o "$work/driver.o" "$dir/runtime/driver.c" || exit 1

fail=0
n=0
for lua in "$dir"/lower/*.lua; do
  base=$(basename "$lua" .lua)
  "$LUA" "$dir/dump.lua" "$lua" "$work/$base.luac" full || { echo "FAIL $base: dump"; fail=1; continue; }
  if ! "$work/lower" "$work/$base.luac" > "$work/$base.ir" 2> "$work/$base.err"; then
    echo "FAIL $base: lowering refused: $(cat "$work/$base.err")"
    fail=1
    continue
  fi
  if ! "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err"; then
    echo "FAIL $base: emitter: $(cat "$work/$base.err")"
    fail=1
    continue
  fi
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "FAIL $base: qbe: $(cat "$work/$base.err")"; fail=1; continue; }
  cc -o "$work/$base" "$work/$base.s" "$work/rt.o" "$work/driver.o" -lm || { echo "FAIL $base: link"; fail=1; continue; }
  got=$("$work/$base") || { echo "FAIL $base: the program exited with status $?"; fail=1; continue; }
  want=$("$LUA" -e "print((dofile('$lua')))")
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL $base: got $got, Lua gives $want"
    fail=1
  fi
done

# A program with an opcode that is not lowered yet (a table constructor) must be refused, not compiled.
cat > "$work/refuse.lua" <<'LUA'
local t = {}
return 1
LUA
"$LUA" "$dir/dump.lua" "$work/refuse.lua" "$work/refuse.luac" full
if "$work/lower" "$work/refuse.luac" > "$work/refuse.ir" 2> "$work/refuse.err"; then
  echo "FAIL refuse: a program with CALL was lowered"
  fail=1
elif [ "$?" -ne 3 ] || ! grep -q "refused:" "$work/refuse.err"; then
  echo "FAIL refuse: wrong refusal: $(cat "$work/refuse.err")"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "lua54bc-lower: FAILED"
  exit 1
fi
echo "lua54bc-lower: $n programs run and match Lua 5.4.9; NEWTABLE is refused"
