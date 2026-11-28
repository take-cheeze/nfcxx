#!/usr/bin/env bash
# Builds the fork's mruby-marshal (3rd/mruby/mrbgems/mruby-marshal/src/marshal.cpp) against the compatibility layer, links it with
# the mrbbc runtime, and runs marshal_link_test.cpp: mrb_marshal_dump and mrb_marshal_load on the 28 values of marshal_test.c.
# The output is compared with marshal_link_expected.txt: the fork's own bytes. 21 cases are exactly CRuby's Marshal.dump; the
# 7 string cases are the fork's bare strings (it writes no encoding wrapper), so they differ from CRuby by design.
set -eu
root=$(cd "$(dirname "$0")/../../../../.." && pwd)
rt=$root/tests/mrbbc/runtime
mr=$root/3rd/mruby
work=${TMPDIR:-/tmp}/marshal-link.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
cxx=${CXX:-g++}
cc=${CC:-gcc}
"$cc" -std=c99 -Wall -Wextra -Wno-unused-parameter -Werror -DMRBBC_VALUE=8 -DMRBBC_GC_CONSERVATIVE=1 -c "$rt/mrbrt.c" -o "$work/mrbrt.o" -lm
"$cxx" -std=c++17 -O1 -c -I"$rt/mruby_compat" -I"$mr/mrbgems/mruby-marshal/include" -I"$mr/include" \
  -DMRUBY_RELEASE_MAJOR=4 -DMRUBY_RELEASE_MINOR=0 -DMRBBC_VALUE=8 "$mr/mrbgems/mruby-marshal/src/marshal.cpp" -o "$work/marshal.o"
"$cxx" -std=c++17 -Wall -Wno-unused-parameter -Wno-unused-variable -DMRBBC_VALUE=8 -DMRBBC_GC_CONSERVATIVE=1 \
  -I"$rt/mruby_compat" -I"$mr/include" -o "$work/marshal_link_test" "$rt/mruby_compat/test/marshal_link_test.cpp" \
  "$work/marshal.o" "$work/mrbrt.o" -lm
"$work/marshal_link_test" > "$work/got.txt"
if diff -q "$rt/mruby_compat/test/marshal_link_expected.txt" "$work/got.txt" >/dev/null; then
  echo "marshal link: the fork's marshal output matches the expected bytes (28 cases, every dump reloads)"
else
  echo "FAIL marshal link:"; diff "$rt/mruby_compat/test/marshal_link_expected.txt" "$work/got.txt" | head -20; exit 1
fi
