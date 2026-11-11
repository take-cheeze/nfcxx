#!/usr/bin/env bash
# Build the ASTro luastro interpreter that lib/poly (nfcpoly_astro.cpp) embeds, into build/poly-astro/<backend>/:
#   lib/libluastro.a   luastro (sample/luastro of ko1/astro: a Lua 5.4 subset on ASTro's generated AST interpreter) as a library:
#                      lib/poly/nfcpoly_astro_shim.c (luastro's main.c without the command line) and the generated node.c
#   include/           nfcpoly_astro_shim.h; give the host program -I build/poly-astro/<backend>/include, and link
#                      -ldl -lm -lpthread after the library
# The evaluator is generated from node.def by ASTroGen (Ruby), the same way tests/realworld/run_astro.sh does it, with the same two
# patches, applied to a copy (the clone stays at the pin): Ruby 3.4's implicit `it` becomes `_1` (the host may have Ruby 3.3), and the
# `;;` that ASTroGen writes between allocator declarations (not ISO C; cproc rejects it) becomes a newline. docs/notes/astro.md.
#   NFCXX_BACKEND=qbe|gcc   back end of the C compiler (default qbe); one build tree per back end
#   FORCE=1                 rebuild even if the library is newer than this script and the shim
# Exit status: 0 built (or up to date); 3 cannot be built here (no ruby, ko1/astro cannot be fetched): tests/poly/run.sh reports a
# SKIP; 1 the build failed. Needs EDG's nfcc toolchain (scripts/setup-qbe.sh for the qbe back end).
self=$(realpath "$0")
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/poly-astro
be=${NFCXX_BACKEND:-qbe}
case $be in qbe|gcc) ;; *) echo "setup-poly-astro: NFCXX_BACKEND must be qbe or gcc, not '$be'" >&2; exit 1 ;; esac
pin=68f15d81b8cc378053c78c2a087b691851bdc2ac   # ko1/astro main, same pin as tests/realworld/run_astro.sh
src=$work/src; out=$work/out-$be; dest=$work/$be
skip() { echo "setup-poly-astro: $*" >&2; exit 3; }
fresh() { [ -f "$dest/lib/libluastro.a" ] && [ "$dest/lib/libluastro.a" -nt "$self" ] &&
          [ "$dest/lib/libluastro.a" -nt lib/poly/nfcpoly_astro_shim.c ] && [ "$dest/lib/libluastro.a" -nt lib/poly/nfcpoly_astro_shim.h ]; }
[ -z "${FORCE:-}" ] && fresh && exit 0
command -v ruby >/dev/null || skip "no ruby (ASTroGen, the generator of luastro's evaluator, is a Ruby program)"
mkdir -p "$work"
exec 9>"$work/.lock"; command -v flock >/dev/null && flock 9 || true
[ -z "${FORCE:-}" ] && fresh && exit 0
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/ko1/astro || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || skip "fetching ko1/astro $pin failed"
fi
git -C "$src" reset -q --hard "$pin" || exit 1

rm -rf "$out"; mkdir -p "$out/sample"
cp -r "$src/lib" "$src/runtime" "$out/"
cp -r "$src/sample/luastro" "$out/sample/"
d=$out/sample/luastro
sed -i -E 's/\bit\./_1./g; s/#\{it\}/#{_1}/g' "$out/lib/astrogen.rb" "$d/lua_gen.rb"
sed -i 's/build_allocator_decl}\.join(";\\n")/build_allocator_decl}.join("\\n")/' "$out/lib/astrogen.rb"
grep -q 'build_allocator_decl}.join("\\n")' "$out/lib/astrogen.rb" ||
  { echo "setup-poly-astro: the ;; patch no longer applies (astrogen.rb changed); move the pin and the patch together" >&2; exit 1; }
log=$work/build-$be.log; : > "$log"
export LC_ALL=C.UTF-8   # node.def holds non-ASCII text; the generator reads it as UTF-8
if ! (cd "$d" && ruby -I ../../lib -I . -r astrogen -r lua_gen -e 'ASTroGen.start([], node_def_class: LuaNodeDef)') >>"$log" 2>&1 ||
   [ ! -f "$d/node_head.h" ]; then
  tail -20 "$log" >&2; echo "setup-poly-astro: ASTroGen failed (full log: $log)" >&2; exit 1
fi
# luastro's main.c is replaced by the shim; its node.c holds the evaluator glue. -I: the generated headers, the ASTro runtime.
cflags=(-c -O2 -I"$d" -I"$out/runtime" -I"$root/lib/poly")
if ! { NFCXX_BACKEND=$be "$root/nfcc" "${cflags[@]}" "$root/lib/poly/nfcpoly_astro_shim.c" -o "$out/shim.o" &&
       NFCXX_BACKEND=$be "$root/nfcc" "${cflags[@]}" "$d/node.c" -o "$out/node.o"; } >>"$log" 2>&1; then
  tail -30 "$log" >&2; echo "setup-poly-astro: build failed (full log: $log)" >&2; exit 1
fi
# luastro defines lua_arith, lua_concat and lua_len, which the real Lua (liblua.a, the "lua" backend) defines too, and a program that
# links both would not link. Every global lua_* / luaL_* symbol of the two objects is renamed with a prefix (the references too).
nm --defined-only -g "$out/shim.o" "$out/node.o" | awk 'NF == 3 && $3 ~ /^lua(L)?_/ { print $3, "ls_" $3 }' | sort -u > "$out/rename.txt"
for o in shim node; do objcopy --redefine-syms="$out/rename.txt" "$out/$o.o" || { echo "setup-poly-astro: objcopy failed" >&2; exit 1; }; done
rm -f "$out/libluastro.a"; ar rcs "$out/libluastro.a" "$out/shim.o" "$out/node.o"
rm -rf "$dest.new"; mkdir -p "$dest.new/lib" "$dest.new/include"
cp "$out/libluastro.a" "$dest.new/lib/libluastro.a"
cp "$root/lib/poly/nfcpoly_astro_shim.h" "$dest.new/include/"
rm -rf "$dest"; mv "$dest.new" "$dest"
echo "setup-poly-astro: built $dest/lib/libluastro.a (backend $be)" >&2
