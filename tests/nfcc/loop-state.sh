#!/usr/bin/env bash
# The Ruby port of nfcc's option handling (scripts/driver-loop.rb) must leave the same state, and fail or exec the same way,
# as the bash (tests/nfcc/option-state.sh runs nfcc's own code) for every argument list of tests/nfcc/loop-cases.txt.
# A line may start with NAME=VALUE words: they are the environment nfcc reads (NFCXX_BACKEND, NFCXX_GCC_PASSTHROUGH,
# NFCXX_QBE_KERNEL, NFCXX_QBE_TRY); both sides get them, and the port gets them as its --nfcc-* options.
# A case the port refuses as "unported" is counted, not compared.
cd "$(dirname "$0")/../.."
pass=0; fail=0; skipped=0
# The host check nfcc makes for -fno-crossjumping (host_is_gnu_gcc): 1 when gcc is GNU gcc.
host_gnu=0; gcc --version 2>&1 | grep -q 'Free Software Foundation' && host_gnu=1
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  envs=(); args=()
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^[A-Z_]+=.* ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  backend=gcc; pt=0; qk=0; qt=0
  for e in "${envs[@]+"${envs[@]}"}"; do
    case $e in
      NFCXX_BACKEND=*) backend=${e#NFCXX_BACKEND=} ;;
      NFCXX_GCC_PASSTHROUGH=*) pt=1 ;;
      NFCXX_QBE_KERNEL=*) qk=1 ;;
      NFCXX_QBE_TRY=*) qt=1 ;;
    esac
  done
  oracle=$(env "${envs[@]+"${envs[@]}"}" tests/nfcc/option-state.sh "${args[@]}" 2>&1)
  port=$(ruby scripts/driver-loop.rb --nfcc-backend="$backend" --nfcc-passthrough=$pt --nfcc-qbe-kernel=$qk \
           --nfcc-host-gnu-gcc=$host_gnu --nfcc-qbe-try=$qt "${args[@]}" 2>&1)
  case $port in
    unported:*) skipped=$((skipped + 1)); echo "skip $line (not ported yet)"; continue ;;
  esac
  if [ "$oracle" = "$port" ]; then
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
