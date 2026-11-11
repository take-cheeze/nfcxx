#!/usr/bin/env bash
# The x87 long double thunks (docs/notes/pathb-longdouble.md) through the SSA route: three goldens that use them emit
# (scripts/pathb-ssa-build, with scripts/pathb-x87-thunks.rb), link with the long double runtime and the EDG runtime, and
# return the value their source gives in `// EXPECT:`. The probe pc.c is the checked-operation helper (must not trap).
#
#   tests/pathb-ssa-qbe/x87/run.sh      (needs build/edg/lib and build/pathb-ldrt, built by scripts/pathb-ldrt)
cd "$(dirname "$0")/../../.." || exit 2
ldrt=$(scripts/pathb-ldrt) || exit 2
libdir=${EDG_LIB:-build/edg/lib}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/pc.c" <<'C'
#include <stdlib.h>
void pathb_check(int cond, int code) { if (cond) abort(); (void)code; }
C
cc -c -o "$tmp/pc.o" "$tmp/pc.c" || exit 2

fail=0
for m in x87_struct:0 longdouble_ir:7 ldr_ptr_ir:0; do
  name=${m%%:*}
  want=${m##*:}
  if ! ruby scripts/pathb-ssa-build -o "$tmp/$name.s" "tests/pathb-ir/$name.ir" 2> "$tmp/$name.emit"; then
    echo "FAIL x87 $name: not emitted: $(head -n 1 "$tmp/$name.emit")"
    fail=1
    continue
  fi
  if ! cc -no-pie -o "$tmp/$name" "$tmp/$name.s" "$tmp/pc.o" "$ldrt" -L"$libdir" -lC -lstdc++ -lgcc_s -lpthread -lm -latomic 2> "$tmp/$name.ld"; then
    echo "FAIL x87 $name: link: $(head -n 1 "$tmp/$name.ld")"
    fail=1
    continue
  fi
  "$tmp/$name" > "$tmp/$name.out" 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   x87 $name: exit $got"
  else
    echo "FAIL x87 $name: exit $got, want $want"
    fail=1
  fi
done
exit $fail
