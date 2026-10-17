#!/usr/bin/env bash
# A Rust program built by mrustc runs when its C goes through nfcxx's C pipeline (cproc -> QBE, scripts/qbe-cc).
# The standard library is mrustc's gcc-built one. Needs scripts/setup-mrustc.sh first. See docs/notes/mrustc-frontend.md.
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# check NAME SOURCE EXPECTED: the program builds with scripts/mrustc-nfcc.sh, runs, and prints EXPECTED
check() {
  local name=$1 src=$2 want=$3 got rc
  if ! scripts/mrustc-nfcc.sh "$src" -o "$tmp/$name" > "$tmp/$name.log" 2>&1; then
    bad "$name" "build: $(tail -3 "$tmp/$name.log" | tr '\n' ' ')"; return
  fi
  got=$("$tmp/$name" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != "$want" ]; then bad "$name" "exit $rc, output '$got'"; return; fi
  ok "$name"
}

check hello tests/mrustc/hello.rs "Hello, world!"
check vec_sum tests/mrustc/vec_sum.rs "55 10"   # a Vec, an iterator sum and format!: heap allocation and monomorphised std code
# The same program with libcore compiled through nfcxx too (cached in build/mrustc/nfcxx after the first run).
MRUSTC_NFCC_CORE=1 check vec_sum_core tests/mrustc/vec_sum.rs "55 10"
# Every crate of mrustc's link command compiled through nfcxx (the first run builds them all; they are cached after that).
MRUSTC_NFCC_CRATES=all check vec_sum_all tests/mrustc/vec_sum.rs "55 10"

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
