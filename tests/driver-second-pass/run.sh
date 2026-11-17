#!/bin/bash
# scripts/nfcxx-second-pass.rb found must answer what the bash loop of nfcxx's second pass decides (verbatim below) for the host
# symbols and unresolved kernel names: found, not found, empty names, scoped names, names that are prefixes or contain regex
# characters, and missing files.   bash tests/driver-second-pass/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
bash_loop() {   # the driver's loop, verbatim (hsyms and the unresolved file set by the case)
  found=0
  while IFS= read -r k; do
    [ -n "$k" ] && grep -qE "(^|[ :])$k<" "$hsyms" && found=1
  done < "$unresolved"
  echo "$found"
}
run_case() {
  local label=$1 syms=$2 unres=$3
  printf '%b' "$syms" > "$t/syms"; printf '%b' "$unres" > "$t/unres"
  hsyms="$t/syms"; unresolved="$t/unres"
  want=$(bash_loop)
  got=$(ruby "$repo/scripts/nfcxx-second-pass.rb" found "$t/syms" "$t/unres")
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $label: bash $want ruby $got"; fi
}
run_case found 'void foo<int>(int)\n' 'foo\n'
run_case not-found 'void bar<int>(int)\n' 'foo\n'
run_case prefix-only 'void foobar<int>(int)\n' 'foo\n'
run_case scoped 'ns::kern<float>(int)\n' 'kern\n'
run_case inside-name 'x_kern<int>\n' 'kern\n'
run_case regex-chars 'a.b<int>\naxb<int>\n' 'a.b\n'
run_case empty-name 'foo<int>\n' '\n'
run_case multi 'bar<1>\n' 'foo\nbar\n'
run_case empty-syms '' 'foo\n'
run_case empty-unres 'foo<1>\n' ''
run_case internal-scope 'k<1>\n' 'k\n'
echo "driver-second-pass: $pass passed, $fail failed"
[ $fail = 0 ]
