#!/usr/bin/env bash
# The Ruby port of nfcc's option loop (scripts/driver-loop.rb) must leave the same state as the bash loop, and fail with the
# same message, for every argument list of tests/nfcc/loop-cases.txt that the port covers. The bash side is
# tests/nfcc/option-state.sh (which runs nfcc's own loop). A case the port refuses as "unported" is counted, not compared.
cd "$(dirname "$0")/../.."
pass=0; fail=0; skipped=0
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a args <<< "$line"
  oracle=$(tests/nfcc/option-state.sh "${args[@]}" 2>&1)
  port=$(ruby scripts/driver-loop.rb "${args[@]}" 2>&1; echo "rc=$?")
  case $port in
    unported:*|*'unported:'*) skipped=$((skipped + 1)); echo "skip $line (not ported yet)"; continue ;;
  esac
  if [ "$oracle" = "$(printf '%s' "$port" | sed '$d')" ] || [ "$oracle" = "$port" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $line"
    echo "  bash:  $(printf '%s' "$oracle" | tr '\n' '|')"
    echo "  ruby:  $(printf '%s' "$port" | tr '\n' '|')"
  fi
done < tests/nfcc/loop-cases.txt
echo "$pass passed, $fail failed, $skipped not ported yet"
[ "$fail" = 0 ]
