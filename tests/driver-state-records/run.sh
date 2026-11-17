#!/bin/bash
# scripts/nfcxx-state-records.rb must write the same bytes as the bash state_put of nfcxx (copied verbatim below) for the same
# groups: names with values, a name with no value, empty values, values with spaces, $ and =. Compared byte for byte.
#   bash tests/driver-state-records/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
state_put() {  # verbatim from nfcxx
  local n=$1 v
  shift
  printf 'k%s\0' "$n"
  for v in ${1+"$@"}; do printf 'v%s\0' "$v"; done
}
pass=0; fail=0
run_case() {   # run_case LABEL: the groups as the bash writes them, and as the Ruby writer does
  local label=$1
  { state_put root "/r/x y"; state_put tmp ""; state_put cache_log; state_put inputs a.cu b.cu;
    state_put ir_opt "\$HOME=1"; state_put preinc; state_put cuda "-DA=1" ""; state_put obfuscate 0; } > "$t/bash.bin"
  ruby "$repo/scripts/nfcxx-state-records.rb" root "/r/x y" $'\x1e' tmp "" $'\x1e' cache_log $'\x1e' inputs a.cu b.cu $'\x1e' \
    ir_opt "\$HOME=1" $'\x1e' preinc $'\x1e' cuda "-DA=1" "" $'\x1e' obfuscate 0 $'\x1e' > "$t/ruby.bin"
  if cmp -s "$t/bash.bin" "$t/ruby.bin"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $label"; od -c "$t/bash.bin" | head -4; od -c "$t/ruby.bin" | head -4; fi
}
run_case mixed
# a group with no values, and an empty group list
{ state_put only; } > "$t/b2"; ruby "$repo/scripts/nfcxx-state-records.rb" only $'\x1e' > "$t/r2"
if cmp -s "$t/b2" "$t/r2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL name-only"; fi
: > "$t/b3"; ruby "$repo/scripts/nfcxx-state-records.rb" > "$t/r3"
if cmp -s "$t/b3" "$t/r3"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL empty list"; fi
echo "driver-state-records: $pass passed, $fail failed"
[ $fail = 0 ]
