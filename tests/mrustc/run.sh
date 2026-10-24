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
# and 128-bit integers, then the clock, loopback networking, a signal handler, dynamic loading, and checked arithmetic.
# Each expected output was also produced by mrustc's gcc-built standard library, and checked against Rust's semantics.
MRUSTC_NFCC_CRATES=all check threads tests/mrustc/threads.rs "4000 6 [0, 10, 20, 30]"
MRUSTC_NFCC_CRATES=all check fsio tests/mrustc/fsio.rs $'"hello file\\nline two\\n" 20
true'
MRUSTC_NFCC_CRATES=all check proc tests/mrustc/proc.rs $'0 "from child\\n"'
MRUSTC_NFCC_CRATES=all check hashing tests/mrustc/hashing.rs "1000 332833500 Some(961)"
MRUSTC_NFCC_CRATES=all check floats tests/mrustc/floats.rs $'0.3333333333333333 10 0.30000000000000004 1.23456789e5\n3.142 1.4142135623730951'
MRUSTC_NFCC_CRATES=all check i128 tests/mrustc/i128.rs "3626777458843887524118525 -170141183460469231731687303715884105727 18446744073709551615"
MRUSTC_NFCC_CRATES=all check time tests/mrustc/time.rs $'slept at least 30ms: true\nunder 5s: true\nmonotonic: true\nafter 2020: true\n1 500 1500\n2.5ms 42ns\n1\n10'
MRUSTC_NFCC_CRATES=all check net tests/mrustc/net.rs $'loopback: true\ntcp reply: pong:ping\npeer loopback: true\nudp: datagram from loopback: true\nrefused: ConnectionRefused'
MRUSTC_NFCC_CRATES=all check signals tests/mrustc/signals.rs "hits 20"
MRUSTC_NFCC_CRATES=all check dlopen tests/mrustc/dlopen.rs $'strlen via dlsym: 5\nopened libm: true\ncos(0) = 1\nclosed: true\nmissing is null: true\nerror names the library: true'
# Inline asm, outlined into helpers the host C compiler builds (mrustc-prep.rb): named and allocated registers, a
# pointer operand, a byte output, a 16-byte compare-exchange.
check asm tests/mrustc/asm.rs "42 0xf2 false true (3, 4) true false 5 6"
MRUSTC_NFCC_CRATES=all check checked tests/mrustc/checked.rs $'None\nSome(12)\nNone\nNone\nNone\nNone\nNone\nSome(200)\nNone\nNone\nNone\nNone\nNone\nSome(170141183460469231731687303715884105728)\n(127, false)\n(0, true)\n(-2147483648, true)\n-2147483648 246\n-32768 255\nSome(16384)\n3486784401 20'

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
