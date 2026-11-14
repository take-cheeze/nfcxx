# The fixture: a Lua source with a .git, its .c files (lua, luac and linit are left out) and headers. The EDG link is the harness's.
c default "" "" ''
c backend-gcc "NFCXX_BACKEND=gcc" "" ''
c backend-bad "NFCXX_BACKEND=mruby" "" ''
c backend-empty "NFCXX_BACKEND=" "" ''
c fresh "" "" 'mkdir -p build/poly-lua/pathb/lib && : > build/poly-lua/pathb/lib/liblua.a && touch -d "2100-01-01" build/poly-lua/pathb/lib/liblua.a'
c fresh-force "FORCE=1" "" 'mkdir -p build/poly-lua/pathb/lib && : > build/poly-lua/pathb/lib/liblua.a && touch -d "2100-01-01" build/poly-lua/pathb/lib/liblua.a'
c stale "" "" 'mkdir -p build/poly-lua/pathb/lib && : > build/poly-lua/pathb/lib/liblua.a && touch -d "1990-01-01" build/poly-lua/pathb/lib/liblua.a'
c no-eccp "" "" 'rm -f build/edg/bin/eccp'
c no-src "" "" 'rm -rf build/poly-lua/src'
c fetch-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *fetch*) exit 1;; esac
S'
c reset-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *reset*) exit 1;; esac
S'
c pinned-rev "" "" 'cat > "$SB/stubs/git" <<"S"
echo 312b9efaa1061c2c4cad08554dbc1351c3270eef
S'
c compile-fails "" "" 'cat > "$SB/stubs/nfcc" <<"S"
echo "nfcc: error in lapi"; exit 1
S'
c ldo-fails "" "" 'cat > "$SB/stubs/nfcxx" <<"S"
echo "nfcxx: error in ldo"; exit 1
S'
c ar-fails "" "" 'cat > "$SB/stubs/ar" <<"S"
exit 1
S'
c no-headers "" "" 'rm -f build/poly-lua/src/lua.h'
