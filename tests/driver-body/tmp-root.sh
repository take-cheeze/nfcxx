#!/bin/bash
# B6: the Ruby driver owns the temporary root (scripts/nfcxx.rb). After a compile, a refusal and a value option given last, no
# directory the driver made is left under the root (the bash traps remove theirs; the Ruby side removes what they miss).
#   bash tests/driver-body/tmp-root.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/tmp" "$t/src"; printf 'int main(){return 0;}\n' > "$t/src/m.cpp"
pass=0; fail=0
check() {   # check NAME STATUS WANT: the status, and no nfcxx-tmp directory left in the isolated TMPDIR
  local left; left=$(find "$t/tmp" -mindepth 1 -maxdepth 1 | wc -l)
  if [ "$2" = "$3" ] && [ "$left" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: status $2 (want $3), $left left"; fi
}
(cd "$t/src" && NFCXX_RUBY_DRIVER=1 TMPDIR="$t/tmp" "$repo/nfcxx" -c m.cpp -o x.o >/dev/null 2>&1); check "compile" $? 0
(cd "$t/src" && NFCXX_RUBY_DRIVER=1 TMPDIR="$t/tmp" "$repo/nfcxx" --instantiate=bogus -c m.cpp -o y.o >/dev/null 2>&1); check "refusal" $? 2
(cd "$t/src" && NFCXX_RUBY_DRIVER=1 TMPDIR="$t/tmp" "$repo/nfcxx" -c m.cpp -o >/dev/null 2>&1); check "value option last" $? 1
# a SIGTERM during the run (the bash has no chance to remove its directories): the Ruby side still removes the root
(cd "$t/src" && NFCXX_RUBY_DRIVER=1 TMPDIR="$t/tmp" timeout -s TERM 0.2 "$repo/nfcxx" -c m.cpp -o z.o >/dev/null 2>&1); check "SIGTERM mid-run" 124 124
echo "driver-body tmp-root: $pass passed, $fail failed"
[ $fail = 0 ]
