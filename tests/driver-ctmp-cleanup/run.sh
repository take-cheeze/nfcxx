#!/bin/bash
# The C-input directory (ctmp, the objects of the .c inputs) is removed when the driver exits: after a successful -c
# compile, after a failed one, and after a link of C objects. The gcc backend builds C without EDG, so this runs
# without an EDG build. The link step may leave the gcc-cc directory of scripts/gcc-cc.rb; that one is not the driver's
# and is not counted here.
#   bash tests/driver-ctmp-cleanup/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int f(int x){return x+1;}\n' > a.c
printf 'int f(int);int main(){return f(1)-2;}\n' > m.c
printf 'int bad( {\n' > bad.c
tdir="$work/tmp"; mkdir "$tdir"
export TMPDIR="$tdir"

# the C driver directories left in TMPDIR: the driver's are "tmp.*" (mktemp -d); gcc-cc.rb's are "gcc-cc*"
left() { ls -A "$tdir" 2>/dev/null | grep -c '^tmp\.' || true; }

NFCXX_BACKEND=gcc "$repo/nfcxx" -c a.c -o a.o >/dev/null 2>&1; st=$?
if [ $st = 0 ] && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL compile leaves the C directory (status $st, left $(left))"; fi

NFCXX_BACKEND=gcc "$repo/nfcxx" -c bad.c -o bad.o >/dev/null 2>&1; st=$?
if [ $st != 0 ] && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL failed compile leaves the C directory (status $st, left $(left))"; fi

NFCXX_BACKEND=gcc "$repo/nfcxx" -o m m.c a.o >/dev/null 2>&1; st=$?
if [ $st = 0 ] && ./m && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL link leaves the C directory (status $st, left $(left))"; fi

echo "driver-ctmp-cleanup: $pass passed, $fail failed"
[ $fail = 0 ]
