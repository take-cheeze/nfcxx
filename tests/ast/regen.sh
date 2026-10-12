#!/usr/bin/env bash
# Regenerates tests/ast/cases/*.out with a real Lua 5.4 (the reference the engine is compared with). Without LUA=/path/to/lua it
# builds the Lua that scripts/setup-poly-lua.sh fetched (build/poly-lua/src, the pin of docs/notes/poly.md) with the host cc.
# Run it only after checking by hand that a changed output is an intended one.
cd "$(dirname "$0")/../.."
lua=${LUA:-}
if [ -z "$lua" ]; then
  src=build/poly-lua/src
  [ -d "$src" ] || { echo "regen: no Lua source; run scripts/setup-poly-lua.sh first, or pass LUA=/path/to/lua" >&2; exit 1; }
  mkdir -p build/ast-ref
  lua=build/ast-ref/lua
  [ -x "$lua" ] || (cd "$src" && cc -O2 -DLUA_USE_LINUX -o ../../ast-ref/lua $(ls l*.c | grep -v -E '^(luac|onelua|ltests)\.c$') -lm -ldl) || exit 1
fi
cd tests/ast/cases
for f in *.lua; do
  "$OLDPWD/$lua" "$f" > "${f%.lua}.out" 2>/dev/null || { echo "regen: $f failed under the reference Lua" >&2; exit 1; }
  echo "wrote ${f%.lua}.out"
done
