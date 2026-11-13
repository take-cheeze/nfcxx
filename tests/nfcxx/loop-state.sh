#!/usr/bin/env bash
# The Ruby port of nfcxx's argument loop (scripts/nfcxx-loop.rb) must leave the same state, and fail with the same message, as
# nfcxx's own loop (tests/nfcxx/option-state.sh) for every argument list of tests/nfcxx/loop-cases.txt. A case the port refuses
# as "unported" is counted, not compared.
cd "$(dirname "$0")/../.."
pass=0; fail=0; skipped=0
ldav=""
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  # leading NAME=VALUE words are the environment of the line (the variables nfcxx's setup reads): both sides get them
  envs=(); args=()
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^(NFCXX_[A-Z_]+|TMPDIR)= ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  nenv=(); for e in "${envs[@]+"${envs[@]}"}"; do nenv+=("--nfcxx-env=$e"); done
  tmpdir=${TMPDIR-}; for e in "${envs[@]+"${envs[@]}"}"; do case $e in TMPDIR=*) tmpdir=${e#TMPDIR=} ;; esac; done
  oracle=$(env "${envs[@]+"${envs[@]}"}" tests/nfcxx/option-state.sh "${args[@]}" 2>&1)
  port=$(ruby scripts/nfcxx-loop.rb --ld-available="$ldav" --nfcxx-uid="$(id -u)" --nfcxx-tmpdir="$tmpdir" \
           "${nenv[@]+"${nenv[@]}"}" "${args[@]}" 2>&1)
  case $port in
    *"unported: "*) skipped=$((skipped + 1)); echo "skip $line (not ported yet)"; continue ;;
  esac
  if [ "$oracle" = "$port" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $line"
    echo "  bash:  $(printf '%s' "$oracle" | tr '\n' '|' | cut -c1-400)"
    echo "  ruby:  $(printf '%s' "$port" | tr '\n' '|' | cut -c1-400)"
  fi
done < tests/nfcxx/loop-cases.txt
echo "$pass passed, $fail failed, $skipped not ported yet"
[ "$fail" = 0 ]
