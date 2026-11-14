# The fixture: curl (creates its -o file), tar (makes the source tree of a tarball), rake (--version; the build makes the
# library). The default outcome of each step is a success.
c usage-none "" "" ''
c usage-bad "" "gcc" ''
c ruby-ok "" "ruby" ''
c lua-ok "" "lua" ''
c js-ok "" "js" ''
c built-exists "" "js" 'mkdir -p build/poly-host/js && : > build/poly-host/js/.built'
c built-exists-ruby "" "ruby" 'mkdir -p build/poly-host/ruby && : > build/poly-host/ruby/.built'
c force-built "FORCE=1" "js" 'mkdir -p build/poly-host/js && : > build/poly-host/js/.built'
c no-curl "" "js" 'rm -f "$SB/bin/curl"'
c no-tar "" "lua" 'rm -f "$SB/bin/tar"'
c no-gcc "" "js" 'rm -f "$SB/bin/gcc"'
c no-gpp "" "lua" 'rm -f "$SB/bin/g++"'
c no-ar "" "ruby" 'rm -f "$SB/bin/ar"'
c no-ruby "" "ruby" 'rm -f "$SB/bin/ruby"'
c rake-version-fails "" "ruby" 'cat > "$SB/stubs/rake" <<"S"
case "$*" in *--version*) exit 1;; esac
exit 0
S'
c rake-gem-bindir "" "ruby" 'rm -f "$SB/bin/rake"; cat > "$SB/stubs/ruby" <<"S"
case "$*" in *Gem.bindir*) echo "$SB/root/gembin";; esac
S
mkdir -p "$SB/root/gembin" && ln -s "$SB/bin/nfcc" "$SB/root/gembin/rake"'
c rake-ruby-fallback "" "ruby" 'rm -f "$SB/bin/rake"'
c rake-build-fails "" "ruby" 'cat > "$SB/stubs/rake" <<"S"
case "$*" in *--version*) exit 0;; esac
echo "rake: compile error"; exit 1
S'
c rake-no-lib "" "ruby" 'cat > "$SB/stubs/rake" <<"S"
exit 0
S'
c ruby-tar-fails "" "ruby" 'cat > "$SB/stubs/tar" <<"S"
exit 1
S'
c ruby-github-fails "" "ruby" 'cat > "$SB/stubs/curl" <<"S"
out=""; prev=""; url=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
case "$url" in *github*) exit 22;; esac
[ -n "$out" ] && echo x > "$out"
exit 0
S'
c lua-github-fails "" "lua" 'cat > "$SB/stubs/curl" <<"S"
out=""; prev=""; url=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
case "$url" in *github*) exit 22;; esac
[ -n "$out" ] && echo x > "$out"
exit 0
S'
c curl-all-fail "" "js" 'cat > "$SB/stubs/curl" <<"S"
exit 22
S'
c lua-gcc-fails "" "lua" 'cat > "$SB/stubs/gcc" <<"S"
echo "gcc: error"; exit 1
S'
c lua-gpp-fails "" "lua" 'cat > "$SB/stubs/g++" <<"S"
echo "g++: error"; exit 1
S'
c lua-ar-fails "" "lua" 'cat > "$SB/stubs/ar" <<"S"
exit 1
S'
c js-gcc-fails "" "js" 'cat > "$SB/stubs/gcc" <<"S"
exit 1
S'
c lua-no-include "" "lua" 'cat > "$SB/stubs/tar" <<"S"
dir=""; prev=""
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
mkdir -p "$dir/src"; : > "$dir/src/lua.c"; : > "$dir/src/lapi.c"
S'
