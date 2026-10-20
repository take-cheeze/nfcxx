#!/usr/bin/env bash
# A Rust program built by mrustc runs when its monomir dump goes through nfcxx's monomir route
# (monomir-to-pathb -> pathb-qbe, scripts/mrustc-monomir.sh). The standard library is mrustc's
# gcc-built one. Needs scripts/setup-mrustc.sh first. See docs/notes/mrustc-monomir.md.
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# check NAME SOURCE EXPECTED: the program builds with scripts/mrustc-monomir.sh, runs, and prints EXPECTED
check() {
  local name=$1 src=$2 want=$3 got rc
  if ! scripts/mrustc-monomir.sh "$src" -o "$tmp/$name" > "$tmp/$name.log" 2>&1; then
    bad "$name" "build: $(tail -3 "$tmp/$name.log" | tr '\n' ' ')"; return
  fi
  got=$("$tmp/$name" 2>&1); rc=$?
  if [ $rc -ne 0 ] || [ "$got" != "$want" ]; then bad "$name" "exit $rc, output '$got'"; return; fi
  ok "$name"
}

check hello tests/mrustc/hello.rs "Hello, world!"
check vec_sum tests/mrustc/vec_sum.rs "55 10"

# Runtime checks: threads and atomics, file I/O, a child process, a hash map, float formatting,
# and 128-bit integers, then the clock, loopback networking, a signal handler, dynamic loading, and checked arithmetic.
check threads tests/mrustc/threads.rs "4000 6 [0, 10, 20, 30]"
check fsio tests/mrustc/fsio.rs $'"hello file\\nline two\\n" 20
true'
check proc tests/mrustc/proc.rs $'0 "from child\\n"'
check hashing tests/mrustc/hashing.rs "1000 332833500 Some(961)"
check floats tests/mrustc/floats.rs $'0.3333333333333333 10 0.30000000000000004 1.23456789e5\n3.142 1.4142135623730951'
check i128 tests/mrustc/i128.rs "3626777458843887524118525 -170141183460469231731687303715884105727 18446744073709551615"
check time tests/mrustc/time.rs $'slept at least 30ms: true\nunder 5s: true\nmonotonic: true\nafter 2020: true\n1 500 1500\n2.5ms 42ns\n1\n10'
check net tests/mrustc/net.rs $'loopback: true\ntcp reply: pong:ping\npeer loopback: true\nudp: datagram from loopback: true\nrefused: ConnectionRefused'
check signals tests/mrustc/signals.rs "hits 20"
check dlopen tests/mrustc/dlopen.rs $'strlen via dlsym: 5\nopened libm: true\ncos(0) = 1\nclosed: true\nmissing is null: true\nerror names the library: true'
check checked tests/mrustc/checked.rs $'None\nSome(12)\nNone\nNone\nNone\nNone\nNone\nSome(200)\nNone\nNone\nNone\nNone\nNone\nSome(170141183460469231731687303715884105728)\n(127, false)\n(0, true)\n(-2147483648, true)\n-2147483648 246\n-32768 255\nSome(16384)\n3486784401 20'

echo "pass $pass fail $fail"
[ $fail -eq 0 ]
