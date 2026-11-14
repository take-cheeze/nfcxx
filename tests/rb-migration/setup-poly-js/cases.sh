# The fixture: a QuickJS source with a .git, and the Path B harness's cpfe (build/pathb/cmake/bin/cpfe).
c default "" "" ''
c backend-gcc "NFCXX_BACKEND=gcc" "" ''
c backend-bad "NFCXX_BACKEND=clang" "" ''
c backend-empty "NFCXX_BACKEND=" "" ''
c no-harness "" "" 'rm -f build/pathb/cmake/bin/cpfe'
c no-harness-gcc "NFCXX_BACKEND=gcc" "" 'rm -f build/pathb/cmake/bin/cpfe'
c no-harness-env "PATHB_CPFE=/x/cpfe" "" 'rm -f build/pathb/cmake/bin/cpfe'
c fresh "" "" 'mkdir -p build/poly-js/pathb/lib && : > build/poly-js/pathb/lib/libquickjs.a && touch -d "2100-01-01" build/poly-js/pathb/lib/libquickjs.a'
c fresh-force "FORCE=1" "" 'mkdir -p build/poly-js/pathb/lib && : > build/poly-js/pathb/lib/libquickjs.a && touch -d "2100-01-01" build/poly-js/pathb/lib/libquickjs.a'
c stale "" "" 'mkdir -p build/poly-js/pathb/lib && : > build/poly-js/pathb/lib/libquickjs.a && touch -d "1990-01-01" build/poly-js/pathb/lib/libquickjs.a'
c no-src "" "" 'rm -rf build/poly-js/src'
c fetch-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *fetch*) exit 1;; esac
S'
c reset-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *reset*) exit 1;; esac
S'
c clean-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *clean*) exit 1;; esac
S'
c pinned-rev "" "" 'cat > "$SB/stubs/git" <<"S"
echo 6d46d07d04041b40f4f49eaa7fdebe44c314c699
S'
c compile-fails "" "" 'cat > "$SB/stubs/nfcc" <<"S"
echo "nfcc: error in dtoa"; exit 1
S'
c ar-fails "" "" 'cat > "$SB/stubs/ar" <<"S"
exit 1
S'
c no-cp-header "" "" 'rm -f build/poly-js/src/quickjs.h'
