#!/usr/bin/env bash
# Lua 5.4 bytecode -> Path B IR (tools/lua54bc/lua54_lower.cpp), end to end, for the lowered subset.
#
# Each program in this directory is compiled by Lua 5.4.9 (LUA, dump.lua), lowered to IR (lua54_lower), emitted to QBE IL
# by scripts/pathb-qbe-emit.rb (run by scripts/mrb.rb), assembled by QBE, linked with the runtime in tests/lua54bc/runtime,
# and run. Two kinds of program:
#   lower/*.lua   the printed results must equal `print(dofile(...))` from Lua 5.4.9.
#   lower/err/*.lua  the error must equal lua.c's: the first stderr line after its progname (the position and the
#                 message, with the variable info), and the exit status must be 1.
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

# build LUAFILE NAME: the program's binary in $work/NAME, or a failure message on stdout (status 1).
build() {
  local lua=$1 base=$2
  "$LUA" "$dir/dump.lua" "$lua" "$work/$base.luac" full || { echo "dump"; return 1; }
  "$work/lower" "$work/$base.luac" > "$work/$base.ir" 2> "$work/$base.err" || { echo "lowering refused: $(cat "$work/$base.err")"; return 1; }
  "$root/scripts/mrb.rb" "$root/scripts/pathb-qbe-emit.rb" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$root/build/qbe/qbe" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  cc -o "$work/$base" "$work/$base.s" "$work/rt.o" "$work/driver.o" -lm || { echo "link"; return 1; }
}

fail=0
n=0
for lua in "$dir"/lower/*.lua; do
  base=$(basename "$lua" .lua)
  if ! msg=$(build "$lua" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  got=$("$work/$base") || { echo "FAIL $base: the program exited with status $?"; fail=1; continue; }
  want=$("$LUA" -e "print(dofile('$lua'))")
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL $base: got $got, Lua gives $want"
    fail=1
  fi
done

ne=0
for lua in "$dir"/lower/err/*.lua; do
  base=err_$(basename "$lua" .lua)
  if ! msg=$(build "$lua" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  "$work/$base" > /dev/null 2> "$work/$base.stderr"; status=$?
  "$LUA" "$lua" > /dev/null 2> "$work/$base.lua_stderr"; lstatus=$?
  got=$(head -1 "$work/$base.stderr" | sed -E 's/^[^:]*: //')
  want=$(head -1 "$work/$base.lua_stderr" | sed -E 's/^[^:]*: //')
  ne=$((ne + 1))
  if [ "$got" != "$want" ] || [ "$status" -ne "$lstatus" ]; then
    echo "FAIL $base: got [$got] (status $status), Lua gives [$want] (status $lstatus)"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "lua54bc-lower: FAILED"
  exit 1
fi
echo "lua54bc-lower: $n programs match Lua 5.4.9; $ne error messages match lua.c"
