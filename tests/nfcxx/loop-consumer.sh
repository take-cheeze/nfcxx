#!/usr/bin/env bash
# nfcxx's argument loop is a consumer of the Ruby planner's records (scripts/nfcxx-loop.rb --records, between the BEGIN and END
# markers of nfcxx). For every argument list of tests/nfcxx/loop-cases.txt it must leave the state, and end the way, the frozen
# bash loop does (recorded in tests/nfcxx/loop-golden.txt from the frozen driver). The harness's temporary directory and
# the bash's line numbers in an unbound-variable error are normalized: both run in another file.
# The driver text is the pre-switch ./nfcxx, pinned (pinned-nfcxx.txt): ./nfcxx is the Ruby driver since B8 and has no loop.
#   tests/nfcxx/loop-consumer.sh     prints the counts; exits nonzero on a failure
cd "$(dirname "$0")/../.."
root=$PWD
pass=0; fail=0
norm() { sed -E 's|/[^ ]*/harness\.sh: line [0-9]+:|HARNESS:|'; }
# golden_block CASE out|status: what loop-golden.txt records for the case line CASE (its output, or its status)
golden_block() {
  CASE_KEY="@@ $1" KIND=$2 awk '
    found == 0 && $0 == ENVIRON["CASE_KEY"] { found = 1; st = 1; next }
    found && /^@@ / { exit }
    found && st { st = 0; if (ENVIRON["KIND"] == "status") print substr($0, 9); next }
    found && ENVIRON["KIND"] == "out" { print }' tests/nfcxx/loop-golden.txt
}
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  envs=(); args=()
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^(NFCXX_[A-Z_]+|TMPDIR|CUDA_HOME|ROCM|CUDA_TEST_[A-Z_]+)= ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  want=$(golden_block "$line" out); ws=$(golden_block "$line" status)
  got=$(env "${envs[@]+"${envs[@]}"}" OPTION_STATE_SRC="$root/tests/nfcxx/pinned-nfcxx.txt" tests/nfcxx/option-state.sh "${args[@]}" 2>&1 | norm); gs=${PIPESTATUS[0]}
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
