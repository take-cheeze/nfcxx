# The fixture: ko1/astro's sources (a .git, lib/astrogen.rb with the two patched lines, sample/luastro), the shim, a ruby stub
# that writes ASTroGen's node_head.h, and an nm stub with the lua_* and luaL_* symbols.
c default "" "" ''
c backend-gcc "NFCXX_BACKEND=gcc" "" ''
c backend-bad "NFCXX_BACKEND=clang" "" ''
c no-ruby "" "" 'rm -f "$SB/bin/ruby"'
c fresh "" "" 'mkdir -p build/poly-astro/pathb/lib && : > build/poly-astro/pathb/lib/libluastro.a && touch -d "2100-01-01" build/poly-astro/pathb/lib/libluastro.a'
c fresh-force "FORCE=1" "" 'mkdir -p build/poly-astro/pathb/lib && : > build/poly-astro/pathb/lib/libluastro.a && touch -d "2100-01-01" build/poly-astro/pathb/lib/libluastro.a'
c stale-shim "" "" 'mkdir -p build/poly-astro/pathb/lib && : > build/poly-astro/pathb/lib/libluastro.a && touch -d "2050-01-01" build/poly-astro/pathb/lib/libluastro.a && touch -d "2100-01-01" lib/poly/nfcpoly_astro_shim.c'
c no-src "" "" 'rm -rf build/poly-astro/src'
c fetch-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *fetch*) exit 1;; esac
S'
c reset-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *reset*) exit 1;; esac
S'
c pinned-rev "" "" 'cat > "$SB/stubs/git" <<"S"
echo 68f15d81b8cc378053c78c2a087b691851bdc2ac
S'
c patch-gone "" "" 'printf "nothing here\n" > build/poly-astro/src/lib/astrogen.rb'
c astrogen-fails "" "" 'cat > "$SB/stubs/ruby" <<"S"
case "$*" in *ASTroGen*) echo "astrogen: error"; exit 1;; esac
S'
c astrogen-no-head "" "" 'cat > "$SB/stubs/ruby" <<"S"
exit 0
S'
c nfcc-fails "" "" 'cat > "$SB/stubs/nfcc" <<"S"
echo "nfcc: error"; exit 1
S'
c objcopy-fails "" "" 'cat > "$SB/stubs/objcopy" <<"S"
exit 1
S'
c nm-empty "" "" 'cat > "$SB/stubs/nm" <<"S"
S'
c no-src-lib "" "" 'rm -rf build/poly-astro/src/lib'
