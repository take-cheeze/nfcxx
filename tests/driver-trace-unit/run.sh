#!/bin/bash
# scripts/nfcxx-trace-unit.rb plan must give the trace_unit the bash line of nfcxx gives (verbatim below), for an unset, an empty
# and a set first source, with and without an output name.   bash tests/driver-trace-unit/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
for case in unset empty named; do for out in a.out prog; do
  srcs=(); out="$out"
  case $case in
    empty) srcs=("") ;;
    named) srcs=(m.cpp) ;;
  esac
  if [ $case = unset ]; then s0set=0; s0=""; else s0set=1; s0="${srcs[0]}"; fi
  trace_unit=${srcs[0]-$out}                                   # the bash line, verbatim
  want=$trace_unit
  eval "$(ruby "$repo/scripts/nfcxx-trace-unit.rb" plan srcs0_set="$s0set" srcs0="$s0" out="$out")"
  if [ "$want" = "$trace_unit" ] && [ "$NFCXX_TRACE_UNIT" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $case out=$out: bash [$want] ruby [$trace_unit] exported [${NFCXX_TRACE_UNIT-unset}]"; fi
done; done
echo "driver-trace-unit: $pass passed, $fail failed"
[ $fail = 0 ]
