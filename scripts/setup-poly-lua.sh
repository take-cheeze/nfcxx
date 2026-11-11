#!/usr/bin/env bash
# Build the Lua that lib/poly (nfcpoly_lua.cpp) embeds, with C++ exceptions, into build/poly-lua/<backend>/:
#   lib/liblua.a   the Lua 5.4 core and the base, coroutine, table, string, math and utf8 libraries
#   include/       lua.h, luaconf.h, lauxlib.h, lualib.h; give the host program -I build/poly-lua/<backend>/include
# Lua has two ways to raise an error: longjmp, or, when the file is compiled as C++, throw. ldo.c is the only file that
# does either, so it is built as C++ by nfcxx (in a generated wrapper that includes it inside extern "C") and every other
# file as C by nfcc: a Lua error is then a throw on EDG's exception runtime, the one the host's throw and catch use, and it
# runs the destructors of the C++ frames it crosses. See docs/notes/poly.md.
# Not built: lua.c, luac.c, linit.c (it would open io, os, package, debug), liolib.c, loslib.c, loadlib.c, ldblib.c. A script
# gets no files, no os.exit and no clock unless the host binds them.
#   NFCXX_BACKEND=qbe|gcc   back end of both compilers (default qbe); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than this script and the patch
# Needs EDG (scripts/setup-edg.sh) and, for the qbe back end, QBE and cproc (scripts/setup-qbe.sh). The Lua source is
# fetched from GitHub at the pin below.
self=$(realpath "$0")
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/poly-lua
be=${NFCXX_BACKEND:-qbe}
case $be in qbe|gcc) ;; *) echo "setup-poly-lua: NFCXX_BACKEND must be qbe or gcc, not '$be'" >&2; exit 1 ;; esac
pin=312b9efaa1061c2c4cad08554dbc1351c3270eef   # lua/lua tag v5.4.9, same pin as tests/realworld/run_lua.sh
src=$work/src; out=$work/out-$be; dest=$work/$be
fresh() { [ -f "$dest/lib/liblua.a" ] && [ "$dest/lib/liblua.a" -nt scripts/lua-cxx-novolatile.patch ] &&
          [ "$dest/lib/liblua.a" -nt "$self" ]; }
[ -z "${FORCE:-}" ] && fresh && exit 0
[ -x "$root/build/edg/bin/eccp" ] || { echo "setup-poly-lua: EDG not built; run scripts/setup-edg.sh" >&2; exit 1; }
mkdir -p "$work"
exec 9>"$work/.lock"; command -v flock >/dev/null && flock 9 || true
[ -z "${FORCE:-}" ] && fresh && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/lua/lua || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "setup-poly-lua: fetching Lua $pin failed" >&2; exit 1; }
fi
git -C "$src" reset -q --hard "$pin" || exit 1
# scripts/lua-cxx-novolatile.patch: cproc cannot store to a volatile object, and the two volatile members that ldo.c writes
# (lua_longjmp.status, a longjmp guard that real exceptions make redundant, and CallInfo.u.l.trap, which only a signal
# handler could race with) lose the qualifier. Applied to this throwaway checkout.
patch -s -p1 -d "$src" --batch < scripts/lua-cxx-novolatile.patch || { echo "setup-poly-lua: patch failed" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out"
files=()
for f in "$src"/l*.c; do
  case $(basename "$f") in lua.c|luac.c|ltests.c|onelua.c|linit.c|liolib.c|loslib.c|loadlib.c|ldblib.c) ;; *) files+=("$f") ;; esac
done
printf 'extern "C" {\n#include "%s/ldo.c"\n}\n' "$src" > "$out/ldo-cxx.cpp"
log=$work/build-$be.log; : > "$log"
compile() {   # compile FILE.c: C through nfcc, ldo.c as C++ through nfcxx
  local f=$1 b; b=$(basename "$f" .c)
  if [ "$b" = ldo ]; then
    NFCXX_BACKEND=$be "$root/nfcxx" -c -O2 -I"$src" "$out/ldo-cxx.cpp" -o "$out/ldo.o"
  else
    NFCXX_BACKEND=$be "$root/nfcc" -c -O2 -I"$src" "$f" -o "$out/$b.o"
  fi
}
export -f compile; export root be src out
if ! printf '%s\n' "${files[@]}" | xargs -P "$(nproc 2>/dev/null || sysctl -n hw.ncpu)" -I{} bash -c 'compile {}' >>"$log" 2>&1; then
  tail -30 "$log" >&2; echo "setup-poly-lua: build failed (full log: $log)" >&2; exit 1
fi
rm -f "$out/liblua.a"; ar rcs "$out/liblua.a" "$out"/*.o
rm -rf "$dest.new"; mkdir -p "$dest.new/lib" "$dest.new/include"
cp "$out/liblua.a" "$dest.new/lib/liblua.a"
cp "$src/lua.h" "$src/luaconf.h" "$src/lauxlib.h" "$src/lualib.h" "$dest.new/include/"
rm -rf "$dest"; mv "$dest.new" "$dest"
echo "setup-poly-lua: built $dest/lib/liblua.a (backend $be, C++ exceptions)" >&2
