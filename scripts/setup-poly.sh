#!/usr/bin/env bash
# Build the mruby that lib/poly (nfcpoly) embeds, with C++ exceptions, into build/poly/<backend>/:
#   lib/libmruby.a    the mruby VM, the compiler (scripts are parsed at run time) and the gems of scripts/mruby-rt-config.rb
#   include/          mruby.h, mruby/*.h and the generated headers; give the host program -I build/poly/<backend>/include
# C sources are compiled by nfcc and the files that mruby builds as C++ under MRB_USE_CXX_EXCEPTION (vm.c, error.c, gc.c
# and the compiler gem's parser and code generator) by nfcxx, so mruby's raise is a throw on EDG's exception runtime.
# See docs/notes/poly.md.
#   NFCXX_BACKEND=qbe|gcc   back end of both compilers (default qbe); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than the config and this script
# Needs ruby and the rake gem (the same bootstrap as scripts/setup-mruby.sh), EDG (scripts/setup-edg.sh) and, for the
# qbe back end, QBE and cproc (scripts/setup-qbe.sh). The mruby source is fetched from GitHub at the pin below.
self=$(realpath "$0")
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/poly
be=${NFCXX_BACKEND:-qbe}
case $be in qbe|gcc) ;; *) echo "setup-poly: NFCXX_BACKEND must be qbe or gcc, not '$be'" >&2; exit 1 ;; esac
pin=831da26b9021de0369d17b71b5667e2941a1a32d   # mruby/mruby tag 4.0.0, same pin as scripts/setup-mruby.sh
src=$work/src; out=$work/out-$be; dest=$work/$be
fresh() { [ -f "$dest/lib/libmruby.a" ] && [ "$dest/lib/libmruby.a" -nt scripts/mruby-rt-config.rb ] &&
          [ "$dest/lib/libmruby.a" -nt scripts/mruby-cxx-novolatile.patch ] && [ "$dest/lib/libmruby.a" -nt "$self" ]; }
[ -z "${FORCE:-}" ] && fresh && exit 0
command -v ruby >/dev/null || { echo "setup-poly: ruby (CRuby) is needed to bootstrap mruby's build" >&2; exit 1; }
if command -v rake >/dev/null; then rake=(rake)
elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
"${rake[@]}" --version >/dev/null 2>&1 || { echo "setup-poly: the rake gem is needed (apt-get install rake)" >&2; exit 1; }
[ -x "$root/build/edg/bin/eccp" ] || { echo "setup-poly: EDG not built; run scripts/setup-edg.sh" >&2; exit 1; }
mkdir -p "$work"
# One build at a time per tree (rake writes into the source tree's .lock files and the build directory).
exec 9>"$work/.lock"; command -v flock >/dev/null && flock 9 || true
[ -z "${FORCE:-}" ] && fresh && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/mruby/mruby || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "setup-poly: fetching mruby $pin failed" >&2; exit 1; }
fi
git -C "$src" reset -q --hard "$pin" || exit 1
# One patch (scripts/mruby-cxx-novolatile.patch): cproc cannot store to a volatile object, and the one volatile in the
# files mruby builds as C++ is a setjmp guard that C++ exceptions make redundant. Applied to this throwaway checkout.
patch -s -p1 -d "$src" --batch < scripts/mruby-cxx-novolatile.patch || { echo "setup-poly: patch failed" >&2; exit 1; }
# mruby writes a .lock file next to its config, so the config is copied into the work dir.
cp scripts/mruby-rt-config.rb "$work/build_config-$be.rb"
log=$work/build-$be.log
if ! (cd "$src" && NFCXX_BACKEND=$be MRUBY_CC=$root/nfcc MRUBY_CXX=$root/nfcxx \
        MRUBY_CONFIG=$work/build_config-$be.rb MRUBY_BUILD_DIR=$out "${rake[@]}" -j"$(nproc)" all) >"$log" 2>&1; then
  tail -30 "$log" >&2; echo "setup-poly: build failed (full log: $log)" >&2; exit 1
fi
lib=$out/host/lib/libmruby.a
[ -f "$lib" ] || { echo "setup-poly: $lib missing after the build (log: $log)" >&2; exit 1; }
rm -rf "$dest.new"; mkdir -p "$dest.new/lib" "$dest.new/include"
cp "$lib" "$dest.new/lib/libmruby.a"
cp -r "$src/include/." "$dest.new/include/"
[ ! -d "$out/host/include" ] || cp -r "$out/host/include/." "$dest.new/include/"
rm -rf "$dest"; mv "$dest.new" "$dest"
echo "setup-poly: built $dest/lib/libmruby.a (backend $be, C++ exceptions)" >&2
