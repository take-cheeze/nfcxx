#!/usr/bin/env bash
# Path B SSA regression (docs/notes/pathb-ssa.md, scripts/pathb-ssa.rb).
#  1. Every stage 2 golden (tests/pathb-ir/*.ir) is converted and verified: single definitions, dominance of every use,
#     phi arguments per predecessor. Functions with a switch are reported as unconverted, not failures.
#  2. Each tests/pathb-ssa/cases/NAME.ir runs `main` on the arguments of NAME.args ("ARGS => EXPECTED"): the SSA form
#     must return EXPECTED, and so must the structured form unless the interpreter does not model it (goto).
# No EDG build is needed: the goldens are the input.
cd "$(dirname "$0")/../.."
fail=0
for f in tests/pathb-ir/*.ir tests/pathb-ssa/cases/*.ir; do
  if ! out=$(ruby scripts/pathb-ssa.rb --check "$f" 2>&1); then echo "FAIL verify $f"; echo "$out"; fail=1; fi
done
echo "ok   verify: $(for f in tests/pathb-ir/*.ir tests/pathb-ssa/cases/*.ir; do ruby scripts/pathb-ssa.rb --check "$f" 2>&1; done | grep -v 'switch (its' | awk '{f+=$2; c+=$4; p+=$6} END {printf "%d functions, %d converted, %d slots promoted", f, c, p}')"
for f in tests/pathb-ssa/cases/*.ir; do
  a=${f%.ir}.args
  [ -f "$a" ] || continue
  while read -r line; do
    [ -z "$line" ] && continue
    inp=${line%%=>*}; want=$(echo "${line##*=>}" | tr -d ' ')
    if ! got=$(ruby scripts/pathb-ssa.rb --run $inp "$f" 2>&1); then echo "FAIL run $f [$inp]: $got"; fail=1; continue; fi
    ssa=$(echo "$got" | sed -n 's/.*ssa=\([^ ]*\).*/\1/p'); st=$(echo "$got" | sed -n 's/.*structured=\([^ ]*\).*/\1/p')
    if [ "$ssa" != "$want" ] || { [ "$st" != unsupported ] && [ "$st" != "$want" ]; }; then
      echo "FAIL run $f [$inp]: want $want, got $got"; fail=1
    else
      echo "ok   run $f [$inp] -> $got"
    fi
  done < "$a"
done
# Address-taken slot: `n` (its address is stored into p) must stay in memory; the pointer slot p is promoted.
if ruby scripts/pathb-ssa.rb tests/pathb-ssa/cases/addr_taken.ir | grep -q '(ssa-promoted "p")' &&
   ruby scripts/pathb-ssa.rb tests/pathb-ssa/cases/addr_taken.ir | grep -q '(slot "n" int 4 4)'; then
  echo "ok   addr_taken: n stays in memory, p promoted"
else
  echo "FAIL addr_taken: promotion of an address-taken slot"; fail=1
fi
exit $fail
