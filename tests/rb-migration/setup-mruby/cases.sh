# NAME ENV ARGS SETUP   (the fixture gives a mruby source with a .git, the gems and a ninja that writes the interpreter)
c default "" "" ''
c no-src "" "" 'rm -rf build/mruby-tool/src'
c pinned-rev "" "" 'cat > "$SB/stubs/git" <<"S"
echo 831da26b9021de0369d17b71b5667e2941a1a32d
S'
c fetch-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *fetch*) exit 1;; esac
S'
c checkout-fails "" "" 'cat > "$SB/stubs/git" <<"S"
case "$*" in *checkout*) exit 1;; esac
S'
c exists "" "" 'mkdir -p build/mruby-tool/bin && : > build/mruby-tool/bin/mruby && chmod +x build/mruby-tool/bin/mruby'
c force-exists "FORCE=1" "" 'mkdir -p build/mruby-tool/bin && : > build/mruby-tool/bin/mruby && chmod +x build/mruby-tool/bin/mruby'
c mrb-cc-nfcc "MRUBY_CC=@SB@/root/nfcc" "" ''
c mrb-cc-cc "MRUBY_CC=cc" "" ''
c mrb-cc-empty "MRUBY_CC=" "" ''
c no-ruby "" "" 'rm -f "$SB/bin/ruby"'
c no-ninja "" "" 'rm -f "$SB/bin/ninja"'
c no-make "" "" 'rm -f "$SB/bin/make"'
c no-gem "" "" 'rm -f 3rd/mruby-json/mrbgem.rake'
c no-cc-and-ar "" "" 'rm -f "$SB/bin/cc" "$SB/bin/ar"'
c ninja-fails "" "" 'cat > "$SB/stubs/ninja" <<"S"
echo "ninja: boom"
exit 1
S'
c ninja-no-output "" "" 'rm -f "$SB/stubs/ninja"'
c generate-fails "" "" 'cat > "$SB/stubs/ruby" <<"S"
case "$*" in *generate*) echo "generate: no"; exit 1;; esac
S'
c bad-args "" "--nope" ''
