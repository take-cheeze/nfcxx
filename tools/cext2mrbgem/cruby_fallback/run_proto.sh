#!/bin/bash
# Prototype (opt-in, --cruby-fallback): builds the CRuby-fallback runtime and its two tests, then runs them.
#   test/cf_test.c  - the CRuby side alone (no mruby): boots the embedded VM, loads the original extension, calls it with
#                     Marshal bytes at the boundary
#   test/fb_e2e.c   - mruby calls the CRuby extension through the glue (Marshal.dump / Marshal.load), in one process
# usage: run_proto.sh [MRUBY_TREE]   (default: REPO/3rd/mruby). The fork's host build with mruby-marshal (mruby_config.rb) goes
# to WORK/mruby-build; the CRuby headers and libruby come from the ruby on PATH, which must be a libruby.so build.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
MT=${1:-$REPO/3rd/mruby}
WORK=${NFCX_CRUBY_PROTO_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
RAKE=${RAKE:-rake}
RUBY_INC=$(ruby -e 'print RbConfig::CONFIG["rubyhdrdir"]')
RUBY_ARCH_INC=$(ruby -e 'print RbConfig::CONFIG["arch"]')
RUBY_LIBDIR=$(ruby -e 'print RbConfig::CONFIG["libdir"]')
CFLAGS="-std=c99 -Wall -Wno-unused-parameter -Werror"

# the fork's host build with mruby-marshal, in its own build directory (the submodule's build is left alone)
if [ ! -f "$WORK/mruby-build/host/lib/libmruby.a" ]; then
  (cd "$MT" && MRUBY_CONFIG="$HERE/mruby_config.rb" MRUBY_BUILD_DIR="$WORK/mruby-build" "$RAKE" -j8 >"$WORK/mruby-build.log" 2>&1) \
    || { tail -20 "$WORK/mruby-build.log"; exit 1; }
fi
MH="$WORK/mruby-build/host"

# the original CRuby extension (module CF) built as a shared object against the CRuby headers
gcc -shared -fPIC -w -I"$RUBY_INC" -I"$RUBY_INC/$RUBY_ARCH_INC" "$HERE/test/cf_sample.c" -o "$WORK/cf_sample.so"

# the CRuby-side runtime, and the CRuby-only test
gcc $CFLAGS -I"$RUBY_INC" -I"$RUBY_INC/$RUBY_ARCH_INC" -c "$HERE/nfcx_cruby_vm.c" -o "$WORK/vm.o"
gcc $CFLAGS -I"$HERE" -c "$HERE/test/cf_test.c" -o "$WORK/cf_test.o"
gcc -o "$WORK/cf_test" "$WORK/vm.o" "$WORK/cf_test.o" -L"$RUBY_LIBDIR" -lruby -Wl,-rpath,"$RUBY_LIBDIR"
"$WORK/cf_test" "$WORK/cf_sample.so"

# the mruby glue and the end-to-end test against the mruby host library
gcc $CFLAGS -I"$MT/include" -I"$HERE" -c "$HERE/nfcx_cruby_glue.c" -o "$WORK/glue.o"
gcc $CFLAGS -I"$MT/include" -I"$MH/include" -I"$HERE" -c "$HERE/test/fb_e2e.c" -o "$WORK/e2e.o"
# libruby and libmruby both define rb_* compatibility symbols (enc, require, ...). The fallback needs both, so the clashing
# names are made local in a private copy of libmruby: otherwise CRuby's own calls bind to mruby's copies at run time.
comm -12 <(nm -g --defined-only "$MH/lib/libmruby.a" | awk '{print $3}' | sort -u) \
         <(nm -D --defined-only "$RUBY_LIBDIR/libruby.so" | awk '{print $3}' | sort -u) > "$WORK/clash.txt"
cp "$MH/lib/libmruby.a" "$WORK/libmruby-local.a"
objcopy $(sed 's/^/--localize-symbol=/' "$WORK/clash.txt" | tr '\n' ' ') "$WORK/libmruby-local.a"
gcc -o "$WORK/fb_e2e" "$WORK/e2e.o" "$WORK/glue.o" "$WORK/vm.o" "$WORK/libmruby-local.a" -lonig -lstdc++ -lm -ldl -lcrypt \
  -L"$RUBY_LIBDIR" -lruby -Wl,-rpath,"$RUBY_LIBDIR"
"$WORK/fb_e2e" "$WORK/cf_sample.so"
echo "run_proto OK ($WORK)"
