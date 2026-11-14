# NAME ENV ARGS SETUP. The fixture: an mruby source (.git, include/), the build outputs of rake in build/poly/out-*; the
# harness's EDG link (build/edg/bin/eccp) and rake, git and ruby stubs.
c default "" "" ''
c backend-gcc "NFCXX_BACKEND=gcc" "" ''
c backend-bad "NFCXX_BACKEND=clang" "" ''
c backend-empty "NFCXX_BACKEND=" "" ''
c fresh "" "" 'mkdir -p build/poly/pathb/lib && : > build/poly/pathb/lib/libmruby.a && touch -d "2100-01-01" build/poly/pathb/lib/libmruby.a'
c fresh-force "FORCE=1" "" 'mkdir -p build/poly/pathb/lib && : > build/poly/pathb/lib/libmruby.a && touch -d "2100-01-01" build/poly/pathb/lib/libmruby.a'
c stale-lib "" "" 'mkdir -p build/poly/pathb/lib && : > build/poly/pathb/lib/libmruby.a && touch -d "1990-01-01" build/poly/pathb/lib/libmruby.a'
c no-ruby "" "" 'rm -f "$SB/bin/ruby"'
c rake-gem-bindir "" "" 'rm -f "$SB/bin/rake"; cat > "$SB/stubs/ruby" <<"S"
case "$*" in *Gem.bindir*) echo "$SB/root/gembin";; esac
S
mkdir -p "$SB/root/gembin" && ln -s "$SB/bin/nfcc" "$SB/root/gembin/rake"'
c rake-ruby-fallback "" "" 'rm -f "$SB/bin/rake"'
c rake-missing "" "" 'cat > "$SB/stubs/rake" <<"S"
exit 1
S'
c no-eccp "" "" 'rm -f build/edg/bin/eccp'
c no-src "" "" 'rm -rf build/poly/src'
c fetch-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *fetch*) exit 1;; esac
S'
c reset-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *reset*) exit 1;; esac
S'
c build-fails "" "" 'cat > "$SB/stubs/rake" <<"S"
echo "rake: compile error"; exit 2
S'
c no-lib "" "" 'rm -f build/poly/out-pathb/host/lib/libmruby.a'
c no-lib-gcc "NFCXX_BACKEND=gcc" "" 'rm -f build/poly/out-gcc/host/lib/libmruby.a'
c no-include "" "" 'rm -rf build/poly/out-pathb/host/include'
c pinned-rev "" "" 'cat > "$SB/stubs/git" <<"S"
echo 831da26b9021de0369d17b71b5667e2941a1a32d
S'
c nproc-empty "" "" 'cat > "$SB/stubs/nproc" <<"S"
S'
