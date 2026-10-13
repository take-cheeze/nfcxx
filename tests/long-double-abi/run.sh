#!/usr/bin/env bash
# long double across the calling convention (SysV: in memory as an argument, in st(0) as a result), both ways between
# the qbe backend and gcc. The expected output is gcc's (the same programs built by gcc only).
cd "$(dirname "$0")/../.."
d=tests/long-double-abi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
want_a=$(gcc -w -o "$tmp/ref_a" $d/main_qbe.c $d/gcc_side.c -lm 2>/dev/null && "$tmp/ref_a")
want_b=$(gcc -w -o "$tmp/ref_b" $d/main_gcc.c $d/lib_qbe.c $d/gcc_side.c -lm 2>/dev/null && "$tmp/ref_b")
# 1. qbe main calls gcc's functions
NFCXX_BACKEND=qbe ./nfcxx $d/main_qbe.c $d/gcc_side.c -o "$tmp/a" > "$tmp/a.log" 2>&1 || { echo "FAIL build qbe main"; head -3 "$tmp/a.log"; fail=1; }
if [ -x "$tmp/a" ] && [ "$("$tmp/a")" = "$want_a" ]; then echo "ok   qbe calls gcc"; else echo "FAIL qbe calls gcc"; fail=1; fi
# 2. gcc main calls the qbe functions
NFCXX_BACKEND=qbe ./nfcxx -c $d/lib_qbe.c -o "$tmp/lib.o" > "$tmp/b.log" 2>&1 || { echo "FAIL build qbe lib"; head -3 "$tmp/b.log"; fail=1; }
if [ -f "$tmp/lib.o" ] && gcc -w -o "$tmp/b" $d/main_gcc.c "$tmp/lib.o" $d/gcc_side.c "$(scripts/pathb-ldrt)" -lm -lstdc++ -latomic 2>/dev/null && [ "$("$tmp/b")" = "$want_b" ]; then echo "ok   gcc calls qbe"; else echo "FAIL gcc calls qbe"; fail=1; fi
echo "$fail failures"
exit $fail
