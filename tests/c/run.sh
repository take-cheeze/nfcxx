#!/usr/bin/env bash
# C inputs: each tests/c/*.c with a "EXPECT: N" comment is compiled with nfcxx (no EDG) and its exit
# code compared. A .cpp with "// EXPECT: N" and "// SOURCES: a.cpp b.c" is a mixed C + C++ program.
# "XFAIL-qbe: reason" in a test marks a documented limit of the QBE backend; it must fail there and
# an unexpected pass is reported (XPASS, counted as failure so the marker gets removed).
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD; dir=$root/tests/c
backends=${NFCXX_BACKEND:-"gcc qbe"}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; xfail=0
for b in $backends; do
  for f in "$dir"/*.c "$dir"/*.cpp; do
    [ -e "$f" ] || continue
    n=$(basename "$f")
    want=$(sed -n 's/^[/ *]*EXPECT: *\([0-9]*\).*/\1/p' "$f" | head -1)
    [ -n "$want" ] || continue                       # helper source, not a test
    srcs=$(sed -n 's|^// SOURCES: *||p' "$f" | head -1); [ -n "$srcs" ] || srcs=$n
    xf=$(sed -n 's/.*XFAIL-'"$b"': *//p' "$f" | head -1)
    files=(); for s in $srcs; do files+=("$dir/$s"); done
    ok=1; why=""
    if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" -I"$dir" "${files[@]}" -o "$tmp/t" 2>&1); then
      why="build: $(grep -m1 -E 'error|undefined' <<<"$out" || head -1 <<<"$out")"; ok=0
    else
      "$tmp/t" >"$tmp/out" 2>&1; got=$?
      [ $got -eq "$want" ] || { why="want $want got $got"; ok=0; }
    fi
    if [ $ok = 1 ] && [ -z "$xf" ]; then echo "ok   $b $n"; pass=$((pass + 1))
    elif [ $ok = 0 ] && [ -n "$xf" ]; then echo "xfail $b $n: $xf [$why]"; xfail=$((xfail + 1))
    elif [ $ok = 1 ]; then echo "XPASS $b $n: remove the XFAIL-$b marker"; fail=$((fail + 1))
    else echo "FAIL $b $n: $why"; fail=$((fail + 1)); fi
    rm -f "$tmp/t" "$tmp/out"
  done
done
echo "tests/c: $pass passed, $xfail xfail, $fail failed"
[ $fail -eq 0 ]
