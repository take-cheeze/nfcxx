#!/usr/bin/env bash
# long double across the calling convention (SysV: in memory as an argument, in st(0) as a result), both ways between
# Path B and gcc (gcc_side.c is gcc's side: g_sum is a variadic function returning long double, which Path B can call, through a
# thunk made for the call's shape, but not define). The expected output is gcc's (the same programs built by gcc only).
cd "$(dirname "$0")/../.."
d=tests/long-double-abi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
want_a=$(gcc -w -o "$tmp/ref_a" $d/main_qbe.c $d/gcc_side.c -lm 2>/dev/null && "$tmp/ref_a")
want_b=$(gcc -w -o "$tmp/ref_b" $d/main_gcc.c $d/lib_qbe.c $d/gcc_side.c -lm 2>/dev/null && "$tmp/ref_b")
# 1. Path B main calls gcc's functions (a variadic call passing long doubles, and returning one, among them)
gcc -w -c $d/gcc_side.c -o "$tmp/side.o" || { echo "FAIL build gcc side"; fail=1; }
./nfcxx $d/main_qbe.c "$tmp/side.o" -o "$tmp/a" > "$tmp/a.log" 2>&1 || { echo "FAIL build pathb main"; head -3 "$tmp/a.log"; fail=1; }
if grep -q 'did not build' "$tmp/a.log"; then echo "FAIL pathb main: Path B refused it"; head -3 "$tmp/a.log"; fail=1; fi
if [ -x "$tmp/a" ] && [ "$("$tmp/a")" = "$want_a" ]; then echo "ok   pathb calls gcc"; else echo "FAIL pathb calls gcc"; fail=1; fi
# 2. gcc main calls the Path B functions
./nfcxx -c $d/lib_qbe.c -o "$tmp/lib.o" > "$tmp/b.log" 2>&1 || { echo "FAIL build pathb lib"; head -3 "$tmp/b.log"; fail=1; }
if grep -q 'did not build\|refused' "$tmp/b.log"; then echo "FAIL pathb lib: Path B refused it"; head -3 "$tmp/b.log"; fail=1; fi
if [ -f "$tmp/lib.o" ] && gcc -w -o "$tmp/b" $d/main_gcc.c "$tmp/lib.o" $d/gcc_side.c "$(scripts/pathb-ldrt)" -lm -lstdc++ -latomic 2>/dev/null && [ "$("$tmp/b")" = "$want_b" ]; then echo "ok   gcc calls pathb"; else echo "FAIL gcc calls pathb"; fail=1; fi
echo "$fail failures"
exit $fail
