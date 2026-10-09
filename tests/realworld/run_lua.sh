#!/usr/bin/env bash
# Real-world check: build the Lua 5.4 interpreter (MIT, pure C) at a pinned upstream release with nfcxx's
# .c input mode and run it. The source is cloned into build/realworld, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# Reports per backend: "built+ran", or the first blocker (build error / wrong run result).
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=312b9efaa1061c2c4cad08554dbc1351c3270eef   # lua/lua tag v5.4.9, 2026-08-07
src=$work/lua
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/lua/lua || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP lua: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL lua: checkout $pin failed"; exit 1; }

# The interpreter: every l*.c except luac.c (the compiler), ltests.c (test hooks) and onelua.c (amalgamation).
srcs=()
for f in "$src"/*.c; do
  case $(basename "$f") in luac.c|ltests.c|onelua.c) ;; *) srcs+=("$f") ;; esac
done

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  exe=$tmp/lua-$b
  if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" "${srcs[@]}" -lm -o "$exe" 2>&1); then
    echo "FAIL $b lua: build blocked: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; fail=1; continue
  fi
  got=$("$exe" -e "print(1+1)" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != 2 ]; then
    echo "FAIL $b lua: built, but -e 'print(1+1)' gave rc=$rc output='$got'"; fail=1; continue
  fi
  got=$("$exe" "$root/tests/realworld/lua_test.lua" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [[ $got != $'lua-ok\t27\t6765\tLua 5.4' ]]; then
    echo "FAIL $b lua: built, print ok, test script rc=$rc output='$got'"; fail=1; continue
  fi
  echo "ok   $b lua: built and ran (print(1+1), string/table/pcall script)"
done
exit $fail
