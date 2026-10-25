#!/usr/bin/env bash
# C inputs: each tests/c/*.c with a "EXPECT: N" comment is compiled with nfcxx (no EDG) and its exit
# code compared. A .cpp with "// EXPECT: N" and "// SOURCES: a.cpp b.c" is a mixed C + C++ program.
# "XFAIL-qbe: reason" in a test marks a documented limit of the QBE backend; it must fail there and
# an unexpected pass is reported (XPASS, counted as failure so the marker gets removed).
# A "// GCC: a.c" line compiles a.c with the host gcc (not the backend under test) and links its object in: a test
# of an ABI between nfcxx's C and gcc's C (float16_abi_gcc.c).
# "// LONG-DOUBLE-16: reason" skips a test on Apple arm64, where long double is 8 bytes.
# "// ELF-ONLY: reason" skips a test on macOS (Mach-O, where the gcc backend is Apple clang): GNU C of ELF targets.
# "// X86-ONLY: reason" skips a test on every backend off x86-64; "// X86-ONLY-qbe: reason" only on that backend (the
# x87 long double and __float128 helpers of be/nfcxx_ldrt.c are x86-64 only).
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
    xf=$(sed -n "s,^// XFAIL-$b: *,,p" "$f" | head -1)   # anchored: MACOS-XFAIL- is a different marker
    # MACOS-XFAIL-$b: a documented limit on macOS only (the test passes elsewhere, so it is not an XFAIL there).
    if [ "$(uname -s)" = Darwin ] && [ -z "$xf" ]; then xf=$(sed -n "s,^// MACOS-XFAIL-$b: *,,p" "$f" | head -1); fi
    x86only=$({ sed -n 's,^// X86-ONLY: *,,p' "$f"; sed -n "s,^// X86-ONLY-$b: *,,p" "$f"; } | head -1)
    if [ -n "$x86only" ] && [ "$(uname -m)" != x86_64 ]; then echo "skip $b $n (x86-64 only: $x86only)"; continue; fi
    elfonly=$(sed -n 's,^// ELF-ONLY: *,,p' "$f" | head -1)
    if [ -n "$elfonly" ] && [ "$(uname -s)" = Darwin ]; then echo "skip $b $n (ELF only: $elfonly)"; continue; fi
    ld16=$(sed -n 's,^// LONG-DOUBLE-16: *,,p' "$f" | head -1)
    if [ -n "$ld16" ] && [ "$(uname -s)-$(uname -m)" = Darwin-arm64 ]; then echo "skip $b $n (long double is 8 bytes here: $ld16)"; continue; fi
    files=(); for s in $srcs; do files+=("$dir/$s"); done
    for s in $(sed -n 's|^// GCC: *||p' "$f" | head -1); do
      gcc -c -O2 -fwrapv "$dir/$s" -o "$tmp/gcc-$s.o" || { echo "FAIL $b $n: gcc could not compile $s"; fail=$((fail + 1)); continue 2; }
      files+=("$tmp/gcc-$s.o")
    done
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
