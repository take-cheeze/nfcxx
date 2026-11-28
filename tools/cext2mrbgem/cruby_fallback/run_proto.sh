#!/bin/bash
# Prototype (opt-in, --cruby-fallback): builds the CRuby-fallback runtime and its two tests, then runs them.
#   test/cf_test.c  - the CRuby side alone (no mruby): boots the embedded VM, loads the original extension, calls it
#   test/fb_e2e.c   - mruby calls the CRuby extension through the glue, in one process
# usage: run_proto.sh [MRUBY_BUILD_HOST_DIR]   (default: REPO/3rd/mruby/build/host, built with rake)
# The CRuby headers and libruby come from the ruby on PATH (rbconfig), which must be a shared-library build (libruby.so).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
MH=${1:-$REPO/3rd/mruby/build/host}
WORK=${NFCX_CRUBY_PROTO_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
RUBY_INC=$(ruby -e 'print RbConfig::CONFIG["rubyhdrdir"]')
RUBY_ARCH_INC=$(ruby -e 'print RbConfig::CONFIG["arch"]')
RUBY_LIBDIR=$(ruby -e 'print RbConfig::CONFIG["libdir"]')
CFLAGS="-std=c99 -Wall -Wno-unused-parameter -Werror"

# the original CRuby extension (module CF) built as a shared object against the CRuby headers
gcc -shared -fPIC -w -I"$RUBY_INC" -I"$RUBY_INC/$RUBY_ARCH_INC" "$HERE/test/cf_sample.c" -o "$WORK/cf_sample.so"

# the CRuby-side runtime, and the CRuby-only test
gcc $CFLAGS -I"$RUBY_INC" -I"$RUBY_INC/$RUBY_ARCH_INC" -c "$HERE/nfcx_cruby_vm.c" -o "$WORK/vm.o"
gcc $CFLAGS -I"$HERE" -c "$HERE/test/cf_test.c" -o "$WORK/cf_test.o"
gcc -o "$WORK/cf_test" "$WORK/vm.o" "$WORK/cf_test.o" -L"$RUBY_LIBDIR" -lruby -Wl,-rpath,"$RUBY_LIBDIR"
"$WORK/cf_test" "$WORK/cf_sample.so"

# the mruby glue, and the end-to-end test against the mruby host library
gcc $CFLAGS -I"$MH/../../include" -I"$HERE" -c "$HERE/nfcx_cruby_glue.c" -o "$WORK/glue.o"
gcc $CFLAGS -I"$MH/../../include" -I"$MH/include" -I"$HERE" -c "$HERE/test/fb_e2e.c" -o "$WORK/e2e.o"
# libruby and libmruby both define rb_* compatibility symbols (enc, require, ...). The fallback needs both, so the clashing
# names are made local in a private copy of libmruby: otherwise CRuby's own calls bind to mruby's copies at run time.
comm -12 <(nm -g --defined-only "$MH/lib/libmruby.a" | awk '{print $3}' | sort -u) \
         <(nm -D --defined-only "$RUBY_LIBDIR/libruby.so" | awk '{print $3}' | sort -u) > "$WORK/clash.txt"
cp "$MH/lib/libmruby.a" "$WORK/libmruby-local.a"
objcopy $(sed 's/^/--localize-symbol=/' "$WORK/clash.txt" | tr '\n' ' ') "$WORK/libmruby-local.a"
gcc -o "$WORK/fb_e2e" "$WORK/e2e.o" "$WORK/glue.o" "$WORK/vm.o" "$WORK/libmruby-local.a" -lonig -lm -ldl -lcrypt \
  -L"$RUBY_LIBDIR" -lruby -Wl,-rpath,"$RUBY_LIBDIR"
"$WORK/fb_e2e" "$WORK/cf_sample.so"
echo "run_proto OK ($WORK)"
