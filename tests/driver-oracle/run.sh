#!/bin/bash
# scripts/nfcxx-oracle.rb: the frozen oracle (tests/driver-body/nfcxx-oracle.sh) runs on its own, and --diff compares it with
# the Ruby driver (./nfcxx) on the same command: stdout, stderr and status agree for a compile, a refusal and a -E.
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'int main(){return 0;}\n' > "$t/m.cpp"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
cd "$t"
ruby "$repo/scripts/nfcxx-oracle.rb" --diff -- -c m.cpp -o m.o >/dev/null; check "compile: driver and oracle agree" $?
ruby "$repo/scripts/nfcxx-oracle.rb" --diff -- --instantiate=bogus -c m.cpp -o y.o >/dev/null; check "refusal: driver and oracle agree" $?
ruby "$repo/scripts/nfcxx-oracle.rb" --diff -- -E m.cpp >/dev/null; check "-E: driver and oracle agree" $?
ruby "$repo/scripts/nfcxx-oracle.rb" -- -c m.cpp -o alone.o; check "oracle alone compiles" $?
[ -s alone.o ]; check "oracle alone writes the object" $?
echo "driver-oracle: $pass passed, $fail failed"
[ $fail = 0 ]
