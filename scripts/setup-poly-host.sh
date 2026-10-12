#!/usr/bin/env bash
# Build the interpreters that lib/poly embeds with the HOST compilers (gcc and g++), for machines where nfcxx itself is not built
# (tests/uop/run_poly.sh with UOP_HOST=1): the same engines and settings as scripts/setup-poly.sh (mruby with C++ exceptions),
# scripts/setup-poly-lua.sh (Lua with ldo.c as C++) and scripts/setup-poly-js.sh (QuickJS-NG, plain C), without nfcc or nfcxx and
# without the patches that only cproc needs. Go (yaegi) is scripts/setup-poly-go.sh, which already uses the host's Go and gcc, and
# Python is the system CPython; neither is built here.
#   scripts/setup-poly-host.sh ruby|lua|js     builds build/poly-host/<language>/{lib,include}
#   FORCE=1                                    rebuild even if the library exists
# Exit status: 0 built (or up to date); 3 cannot be built here (a tool or a download is missing); 1 the build failed.
# Sources, at the pins of the other setup scripts: mruby 4.0.0 and Lua 5.4.9 as the source tarballs of the Ubuntu archive (checked
# against the sha256 below; the upstream tag tarball of GitHub is tried first) and QuickJS-NG v0.17.0 file by file from
# raw.githubusercontent.com at the commit of the tag. Needs curl, tar, gcc, g++, ar; ruby with rake for mruby.
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/poly-host
lang=${1:-}
skip() { echo "setup-poly-host: $*" >&2; exit 3; }
case $lang in ruby|lua|js) ;; *) echo "usage: $0 ruby|lua|js" >&2; exit 1 ;; esac
for t in curl tar gcc g++ ar; do command -v $t >/dev/null || skip "$t not found"; done
dest=$work/$lang
[ -z "${FORCE:-}" ] && [ -f "$dest/.built" ] && exit 0
mkdir -p "$work"; exec 9>"$work/.lock"; flock 9
[ -z "${FORCE:-}" ] && [ -f "$dest/.built" ] && exit 0
log=$work/build-$lang.log; : > "$log"
fail() { tail -20 "$log" >&2; echo "setup-poly-host: $lang build failed (log: $log)" >&2; exit 1; }

# fetch OUT SHA256 URL...: the first URL that downloads; a download from the Ubuntu archive must match SHA256
fetch() {
  local out=$1 sha=$2 u; shift 2
  for u in "$@"; do
    curl -sSfL -m 120 -o "$out" "$u" 2>>"$log" || continue
    case $u in *archive.ubuntu.com*) [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$sha" ] || { echo "checksum mismatch: $u" >>"$log"; continue; } ;; esac
    return 0
  done
  return 1
}

case $lang in
ruby)
  command -v ruby >/dev/null || skip "ruby (CRuby) is needed to bootstrap mruby's build"
  if command -v rake >/dev/null; then rake=(rake)
  elif [ -x "$(ruby -e 'print Gem.bindir')/rake" ]; then rake=("$(ruby -e 'print Gem.bindir')/rake")
  else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
  "${rake[@]}" --version >/dev/null 2>&1 || skip "the rake gem is needed"
  pin=831da26b9021de0369d17b71b5667e2941a1a32d   # mruby/mruby tag 4.0.0
  src=$work/mruby-src; rm -rf "$src" "$work/mruby-out"; mkdir -p "$src"
  fetch "$work/mruby.tgz" e2ea271dbed14e9f2b33df773ae447b747dbc242ce2675022c0a57efea85a7b4 \
    "https://github.com/mruby/mruby/archive/$pin.tar.gz" \
    "http://archive.ubuntu.com/ubuntu/pool/universe/m/mruby/mruby_4.0.0.orig.tar.gz" || skip "cannot download mruby 4.0.0"
  tar xzf "$work/mruby.tgz" -C "$src" --strip-components=1 || fail
  # mruby's own rake build, with scripts/mruby-rt-config.rb (C++ exceptions) and the host compilers
  cp scripts/mruby-rt-config.rb "$work/build_config-host.rb"
  if ! (cd "$src" && MRUBY_CC=gcc MRUBY_CXX=g++ MRUBY_CONFIG=$work/build_config-host.rb MRUBY_BUILD_DIR=$work/mruby-out "${rake[@]}" -j"$(nproc)" all) >>"$log" 2>&1; then fail; fi
  lib=$work/mruby-out/host/lib/libmruby.a
  [ -f "$lib" ] || fail
  rm -rf "$dest"; mkdir -p "$dest/lib" "$dest/include"
  cp "$lib" "$dest/lib/"; cp -r "$src/include/." "$dest/include/"; cp -r "$work/mruby-out/host/include/." "$dest/include/"
  ;;
lua)
  src=$work/lua-src; rm -rf "$src"; mkdir -p "$src"
  fetch "$work/lua.tgz" 2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6 \
    "https://github.com/lua/lua/archive/312b9efaa1061c2c4cad08554dbc1351c3270eef.tar.gz" \
    "http://archive.ubuntu.com/ubuntu/pool/main/l/lua5.4/lua5.4_5.4.9.orig.tar.gz" || skip "cannot download Lua 5.4.9"
  tar xzf "$work/lua.tgz" -C "$src" --strip-components=1 || fail
  [ -d "$src/src" ] && src=$src/src
  out=$work/lua-out; rm -rf "$out"; mkdir -p "$out"
  # ldo.c is the one file that raises errors (longjmp, or throw when compiled as C++): it is built as C++, the others as C
  printf 'extern "C" {\n#include "%s/ldo.c"\n}\n' "$src" > "$out/ldo-cxx.cpp"
  for f in "$src"/l*.c; do
    b=$(basename "$f" .c)
    case $b in lua|luac|ltests|onelua|linit|liolib|loslib|loadlib|ldblib) continue ;; esac
    if [ "$b" = ldo ]; then g++ -c -O2 -I"$src" "$out/ldo-cxx.cpp" -o "$out/ldo.o" >>"$log" 2>&1 || fail
    else gcc -c -O2 -I"$src" "$f" -o "$out/$b.o" >>"$log" 2>&1 || fail; fi
  done
  rm -rf "$dest"; mkdir -p "$dest/lib" "$dest/include"
  ar rcs "$dest/lib/liblua.a" "$out"/*.o && cp "$src/lua.h" "$src/luaconf.h" "$src/lauxlib.h" "$src/lualib.h" "$dest/include/" || fail
  ;;
js)
  pin=6d46d07d04041b40f4f49eaa7fdebe44c314c699   # quickjs-ng/quickjs tag v0.17.0
  src=$work/qjs-src; out=$work/qjs-out; rm -rf "$src" "$out"; mkdir -p "$src" "$out"
  for f in quickjs.c quickjs.h dtoa.c dtoa.h libregexp.c libregexp.h libregexp-opcode.h libunicode.c libunicode.h libunicode-table.h \
           cutils.h list.h quickjs-atom.h quickjs-opcode.h quickjs-c-atomics.h builtin-array-fromasync.h builtin-iterator-zip-keyed.h \
           builtin-iterator-zip.h; do
    fetch "$src/$f" "" "https://raw.githubusercontent.com/quickjs-ng/quickjs/$pin/$f" || skip "cannot download QuickJS-NG ($f)"
  done
  for n in quickjs dtoa libregexp libunicode; do gcc -c -O2 -I"$src" "$src/$n.c" -o "$out/$n.o" >>"$log" 2>&1 || fail; done
  rm -rf "$dest"; mkdir -p "$dest/lib" "$dest/include"
  ar rcs "$dest/lib/libquickjs.a" "$out"/*.o && cp "$src/quickjs.h" "$dest/include/" || fail
  ;;
esac
touch "$dest/.built"
echo "setup-poly-host: built $dest" >&2
