#!/usr/bin/env bash
# Build the QuickJS-NG that lib/poly (nfcpoly_js.cpp) embeds into build/poly-js/<backend>/:
#   lib/libquickjs.a   the engine: quickjs.c, dtoa.c, libregexp.c, libunicode.c
#   include/           quickjs.h; give the host program -I build/poly-js/<backend>/include
# QuickJS reports errors as return values (JS_EXCEPTION), never with setjmp/longjmp or a throw, so every file is plain C
# built by nfcc: no C++ build is needed (unlike mruby and Lua). Not built: quickjs-libc.c, qjs.c, qjsc.c. A script gets
# no files, no `os`, no `std`, no module loader, and no timers unless the host binds them.
# QuickJS is compiled without -D_GNU_SOURCE (its CMakeLists defines it, but nothing in the sources needs it on Linux): the
# macro makes glibc's <stdlib.h> and <math.h> declare functions of the types _Float32x and _Float64x, which cproc cannot
# parse (qbe-prep.rb drops those typedefs, so cproc reports `declaration has no type specifier`).
#   NFCXX_BACKEND=qbe|gcc   back end of the C compiler (default qbe); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than this script and the patch
# Needs QBE and cproc for the qbe back end (scripts/setup-qbe.sh), gcc for the gcc back end, and git, patch, flock and ar. The
# source is fetched from GitHub at the pin.
# scripts/quickjs-cproc.patch is applied to the throwaway checkout, for both back ends: four spots that cproc cannot compile
# (docs/notes/poly.md, "JavaScript: QuickJS-NG in plain C"). Where the change would cost gcc something it is selected with
# `__CPROC__`, which the qbe back end defines: the switch dispatch of the interpreter loop instead of computed goto, and
# libatomic's sized functions instead of <stdatomic.h>'s _Atomic.
self=$(realpath "$0")
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/poly-js
be=${NFCXX_BACKEND:-qbe}
case $be in qbe|gcc) ;; *) echo "setup-poly-js: NFCXX_BACKEND must be qbe or gcc, not '$be'" >&2; exit 1 ;; esac
pin=6d46d07d04041b40f4f49eaa7fdebe44c314c699   # quickjs-ng/quickjs tag v0.17.0
src=$work/src; out=$work/out-$be; dest=$work/$be
fresh() { [ -f "$dest/lib/libquickjs.a" ] && [ "$dest/lib/libquickjs.a" -nt scripts/quickjs-cproc.patch ] &&
          [ "$dest/lib/libquickjs.a" -nt "$self" ]; }
[ -z "${FORCE:-}" ] && fresh && exit 0
if [ "$be" = qbe ]; then
  [ -x "$root/build/qbe/qbe" ] && [ -x "$root/build/cproc/cproc-qbe" ] ||
    { echo "setup-poly-js: QBE not built; run scripts/setup-qbe.sh" >&2; exit 1; }
fi
mkdir -p "$work"
exec 9>"$work/.lock"; flock 9
[ -z "${FORCE:-}" ] && fresh && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/quickjs-ng/quickjs || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  GIT_LFS_SKIP_SMUDGE=1 git -C "$src" fetch -q --depth 1 origin "$pin" ||
    { echo "setup-poly-js: fetching QuickJS-NG $pin failed" >&2; exit 1; }
fi
git -C "$src" reset -q --hard "$pin" || exit 1
git -C "$src" clean -q -fdx || exit 1
patch -s -p1 -d "$src" --batch < scripts/quickjs-cproc.patch || { echo "setup-poly-js: patch failed" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out"
log=$work/build-$be.log; : > "$log"
compile() {   # compile NAME: src/NAME.c with nfcc
  NFCXX_BACKEND=$be "$root/nfcc" -c -O2 -I"$src" "$src/$1.c" -o "$out/$1.o"
}
export -f compile; export root be src out
# quickjs.c is the long pole (about 25 s on the gcc back end), so it starts first.
if ! printf '%s\n' quickjs dtoa libregexp libunicode | xargs -P "$(nproc)" -I{} bash -c 'compile {}' >>"$log" 2>&1; then
  tail -30 "$log" >&2; echo "setup-poly-js: build failed (full log: $log)" >&2; exit 1
fi
rm -f "$out/libquickjs.a"; ar rcs "$out/libquickjs.a" "$out"/quickjs.o "$out"/dtoa.o "$out"/libregexp.o "$out"/libunicode.o
rm -rf "$dest.new"; mkdir -p "$dest.new/lib" "$dest.new/include"
cp "$out/libquickjs.a" "$dest.new/lib/libquickjs.a"
cp "$src/quickjs.h" "$dest.new/include/"
rm -rf "$dest"; mv "$dest.new" "$dest"
echo "setup-poly-js: built $dest/lib/libquickjs.a (backend $be, QuickJS-NG v0.17.0)" >&2
