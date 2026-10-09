#!/usr/bin/env bash
# Real-world check: build Lua 5.4 with ITS OWN makefile, `make CC=<repo>/nfcc`, the way a user would, and run it.
# Same pinned upstream commit as run_lua.sh (cloned into build/realworld/lua, not vendored). The make runs in a
# scratch copy of the sources, so the checkout stays clean.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# Lua's repository ships only the developer's makefile. Its warning list, -march=native, -fno-stack-protector
# and -fno-common all go through nfcc as they are; only MYCFLAGS/MYLIBS are overridden to drop -lreadline
# (not installed here) and the -Wl,-E link flag is kept.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=312b9efaa1061c2c4cad08554dbc1351c3270eef   # lua/lua tag v5.4.9, 2026-08-07
src=$work/lua
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/lua/lua || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP lua-make: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL lua-make: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  d=$tmp/$b; mkdir "$d"
  cp "$src"/*.c "$src"/*.h "$src"/makefile "$d"/
  if ! out=$(cd "$d" && NFCXX_BACKEND=$b make -j4 CC="$root/nfcc" MYCFLAGS='$(LOCAL) -std=c99 -DLUA_USE_LINUX' \
             MYLIBS=-ldl 2>&1); then
    echo "FAIL $b lua-make: build blocked: $(grep -m1 -E 'error|undefined|\*\*\*' <<<"$out" || tail -1 <<<"$out")"; fail=1; continue
  fi
  exe=$d/lua
  got=$("$exe" -e "print(1+1)" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != 2 ]; then
    echo "FAIL $b lua-make: built, but -e 'print(1+1)' gave rc=$rc output='$got'"; fail=1; continue
  fi
  got=$("$exe" "$root/tests/realworld/lua_test.lua" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [[ $got != $'lua-ok\t27\t6765\tLua 5.4' ]]; then
    echo "FAIL $b lua-make: built, print ok, test script rc=$rc output='$got'"; fail=1; continue
  fi
  echo "ok   $b lua-make: make CC=nfcc built liblua.a and lua (ar via makefile), ran print(1+1) and the test script"
done
exit $fail
