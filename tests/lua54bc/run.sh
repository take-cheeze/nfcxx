#!/usr/bin/env bash
# Lua 5.4 binary chunk reader (tools/lua54bc) against Lua 5.4.9.
#
# Two levels, each needing its own tool:
#   LUA   a Lua 5.4.9 interpreter (required). string.dump writes the same binary chunk format as luac (lundump.c and
#         ldump.c are shared), so every corpus file is dumped with and without debug information and must load in
#         lua54_list with exit status 0. This checks the header, every section, and the string/number encodings.
#   LUAC  a Lua 5.4.9 luac (optional). When set, lua54_list's opcode sequence must equal the one in `luac -l -l`, function
#         by function, for both dumps. This is the opcode-level check; it is skipped when LUAC is not set.
#
#   LUA=/path/to/lua [LUAC=/path/to/luac] tests/lua54bc/run.sh
#
# Exit 77 (skip) when LUA is not set or is not Lua 5.4.9.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
src=$root/tools/lua54bc
work=${TMPDIR:-/tmp}/lua54bc-test.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ -z "${LUA:-}" ] || ! "$LUA" -v 2>&1 | grep -q '^Lua 5\.4\.9\b'; then
  echo "lua54bc: skipped (set LUA to a Lua 5.4.9 interpreter)"
  exit 77
fi

c++ -std=c++17 -O1 -Wall -Wextra -o "$work/list" "$src/lua54_chunk.cpp" "$src/lua54_list.cpp" || exit 1

# dump FILE.lua OUT.luac strip|full: the chunk string.dump writes for FILE.lua.
dump() {
  "$LUA" "$root/tests/lua54bc/dump.lua" "$1" "$2" "$3"
}

fail=0
n=0
for lua in "$root"/tests/lua54bc/corpus/*.lua; do
  base=$(basename "$lua" .lua)
  for mode in full strip; do
    chunk=$work/$base.$mode.luac
    dump "$lua" "$chunk" "$mode" || { echo "FAIL $base ($mode): string.dump refused the source"; fail=1; continue; }
    n=$((n + 1))
    if ! "$work/list" "$chunk" > "$work/got.txt" 2> "$work/err.txt"; then
      echo "FAIL $base ($mode): lua54_list refused a real chunk: $(cat "$work/err.txt")"
      fail=1
      continue
    fi
    if [ -n "${LUAC:-}" ]; then
      # Opcode names only, in order: the instruction lines of luac -l -l and of lua54_list.
      "$LUAC" -l -l "$chunk" | awk '/^\t[0-9]+\t\[[0-9-]+\]\t[A-Z]/ { print $3 }' > "$work/ref.txt"
      awk '/^ +[0-9]+ [A-Z]/ { print $2 }' "$work/got.txt" > "$work/mine.txt"
      if ! diff -q "$work/ref.txt" "$work/mine.txt" >/dev/null; then
        echo "FAIL $base ($mode): opcode sequence differs from luac -l -l"
        diff "$work/ref.txt" "$work/mine.txt" | head -20
        fail=1
      fi
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "lua54bc: FAILED"
  exit 1
fi
if [ -n "${LUAC:-}" ]; then
  echo "lua54bc: $n chunks load and match luac 5.4.9 opcodes"
else
  echo "lua54bc: $n chunks load (opcode check skipped: set LUAC)"
fi
