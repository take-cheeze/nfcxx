#!/usr/bin/env bash
# Cross-compile the pinned Lua 5.4 (run_lua.sh's pin) for macOS arm64 on Linux, link it against the clean-room stub
# (tests/macos-sysroot), and write the executable to build/lua-macos/lua. Needs scripts/setup-cross-macos.sh first.
# Nothing is run here: copy build/lua-macos/lua to a Mac and run it there, with tests/realworld/lua_smoke.lua and
# tests/realworld/lua_test.lua; the expected output is "2" for print(1+1) and "lua-ok<TAB>27<TAB>6765<TAB>Lua 5.4".
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; . build/cross-macos.env
pin=312b9efaa1061c2c4cad08554dbc1351c3270eef   # lua/lua tag v5.4.9, as run_lua.sh
src=$root/build/realworld/lua; out=$root/build/lua-macos; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ ! -d "$src/.git" ]; then mkdir -p "$src" && git -C "$src" init -q && git -C "$src" remote add origin https://github.com/lua/lua; fi
git -C "$src" fetch -q --depth 1 origin "$pin" && git -C "$src" checkout -q "$pin"
res=$(clang -print-resource-dir)/include
clang --target=arm64-apple-darwin -O2 -nostdinc -isystem "$NFCXX_MACOS_CLEANROOM/include" -isystem "$res" \
  -c be/nfcxx_ldrt.c -o "$W/ldrt.o"
objs=()
# every interpreter file: luac.c (the compiler), ltests.c (test hooks) and onelua.c (amalgamation) are not part of it
for f in "$src"/l*.c; do
  case $(basename "$f") in luac.c|ltests.c|onelua.c) continue ;; esac
  b=$(basename "$f" .c)
  NFCXX_C_INPUT=1 scripts/qbe-cc -S "$f" -o "$W/$b.s" >/dev/null
  llvm-mc -triple=arm64-apple-darwin -filetype=obj "$W/$b.s" -o "$W/$b.o"
  objs+=("$W/$b.o")
done
mkdir -p "$out"
ld64.lld -arch arm64 -platform_version macos 11.0 11.0 -o "$out/lua" "${objs[@]}" "$W/ldrt.o" \
  -L tests/macos-sysroot/lib -lSystem
echo "built: $out/lua ($(llvm-objdump --macho --private-headers "$out/lua" | grep -c ARM64) ARM64 header)"
