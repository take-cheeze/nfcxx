#!/usr/bin/env bash
# nfcxx's argument loop is a consumer of the Ruby planner's records (scripts/nfcxx-loop.rb --records, between the BEGIN and END
# markers of nfcxx). For every argument list of tests/nfcxx/loop-cases.txt it must leave the state, and end the way, the frozen
# bash loop does (tests/nfcxx/nfcxx-bash, the oracle of tests/nfcxx/option-state.sh). The harness's temporary directory and
# the bash's line numbers in an unbound-variable error are normalized: both run in another file.
#   tests/nfcxx/loop-consumer.sh     prints the counts; exits nonzero on a failure
cd "$(dirname "$0")/../.."
root=$PWD
pass=0; fail=0
norm() { sed -E 's|/[^ ]*/harness\.sh: line [0-9]+:|HARNESS:|'; }
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  envs=(); args=()
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^(NFCXX_[A-Z_]+|TMPDIR|CUDA_HOME|ROCM|CUDA_TEST_[A-Z_]+)= ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  want=$(env "${envs[@]+"${envs[@]}"}" tests/nfcxx/option-state.sh "${args[@]}" 2>&1 | norm); ws=${PIPESTATUS[0]}
  got=$(env "${envs[@]+"${envs[@]}"}" OPTION_STATE_SRC="$root/nfcxx" tests/nfcxx/option-state.sh "${args[@]}" 2>&1 | norm); gs=${PIPESTATUS[0]}
  if [ "$want" = "$got" ] && [ "$ws" = "$gs" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $line"
    echo "  bash:   (status $ws) $(printf '%s' "$want" | tr '\n' '|' | cut -c1-300)"
    echo "  consumer: (status $gs) $(printf '%s' "$got" | tr '\n' '|' | cut -c1-300)"
  fi
done < tests/nfcxx/loop-cases.txt
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
