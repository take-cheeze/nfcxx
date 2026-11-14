#!/bin/bash
# Compares scripts/nfcxx-sanitize.rb with nfcxx's own post-loop -fsanitize block (lines from "if [ -n "$sanitize" ]; then"
# to its "fi"), run in a subshell with sanitize, freestanding and backend set as the loop leaves them.
cd "$(dirname "$0")/../.." || exit 1
start=$(grep -n '^if \[ -n "\$sanitize" \]; then$' nfcxx | cut -d: -f1)
[ -n "$start" ] || { echo "cannot find the sanitize block in nfcxx"; exit 1; }
end=$(awk -v s="$start" 'NR > s && /^fi$/ { print NR; exit }' nfcxx)
snip=$(mktemp); trap 'rm -f "$snip"' EXIT
sed -n "${start},${end}p" nfcxx > "$snip"
pass=0; fail=0
check() {  # check SANITIZE FREESTANDING BACKEND
  local want got
  got=$(ruby scripts/nfcxx-sanitize.rb "$1" "$2" "$3" 2>&1)
  want=$( (sanitize=$1; freestanding=$2; backend=$3; pb_flags=(); source "$snip"
           echo "backend=$backend pb_flags=${pb_flags[*]:-}") 2>&1 ; rc=$?
          echo "status=$rc" )
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL [$1] [$2] [$3]"; echo "  bash: $want"; echo "  ruby: $got"; fi
}
check "" 0 gcc
check undefined 0 gcc
check undefined,bounds 0 gcc
check undefined, 0 gcc
check undefined,,bounds 0 gcc
check ,undefined 0 gcc
check bogus 0 gcc
check address 0 gcc
check undefined 1 gcc
check null 1 pathb
check shift,return 0 pathb
check undefined,bogus 0 gcc
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
