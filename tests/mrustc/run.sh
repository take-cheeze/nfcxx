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

# Runtime checks on the all-crates build: threads and atomics, file I/O, a child process, a hash map, float formatting,
# and 128-bit integers. Each expected output was also produced by mrustc's gcc-built standard library.
MRUSTC_NFCC_CRATES=all check threads tests/mrustc/threads.rs "4000 6 [0, 10, 20, 30]"
MRUSTC_NFCC_CRATES=all check fsio tests/mrustc/fsio.rs $'"hello file\\nline two\\n" 20
true'
MRUSTC_NFCC_CRATES=all check proc tests/mrustc/proc.rs $'0 "from child\\n"'
MRUSTC_NFCC_CRATES=all check hashing tests/mrustc/hashing.rs "1000 332833500 Some(961)"
MRUSTC_NFCC_CRATES=all check floats tests/mrustc/floats.rs $'0.3333333333333333 10 0.30000000000000004 1.23456789e5\n3.142 1.4142135623730951'
MRUSTC_NFCC_CRATES=all check i128 tests/mrustc/i128.rs "3626777458843887524118525 -170141183460469231731687303715884105727 18446744073709551615"

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
