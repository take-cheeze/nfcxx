#!/usr/bin/env bash
# The Ruby port of nfcc's option handling (scripts/driver-loop.rb) must leave the same state, and fail or exec the same way,
# as the bash (tests/nfcc/option-state.sh runs nfcc's own code) for every argument list of tests/nfcc/loop-cases.txt.
# A line may start with NAME=VALUE words: they are the environment nfcc reads (NFCXX_BACKEND, NFCXX_GCC_PASSTHROUGH,
# both sides get them, and the port gets them as its --nfcc-* options.
# A case the port refuses as "unported" is counted, not compared.
cd "$(dirname "$0")/../.."
pass=0; fail=0; skipped=0
# The host check nfcc makes for -fno-crossjumping (host_is_gnu_gcc): 1 when gcc is GNU gcc.
host_gnu=0; gcc --version 2>&1 | grep -q 'Free Software Foundation' && host_gnu=1
os=$(uname -s)
# The -fshort-wchar check runs the host preprocessor; the oracle's -E stub shows a wide literal only with STUB_WIDE_LITERAL.
wide_default=0
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  envs=(); args=(); cuda_home_env=""
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^[A-Z_]+=.* ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  backend=gcc; pt=0; fb=0; pbst=0; host=cc; logf=0; edg=ROOT/build/edg; wide=$wide_default
  for e in "${envs[@]+"${envs[@]}"}"; do
    case $e in
      NFCXX_BACKEND=*) backend=${e#NFCXX_BACKEND=} ;;
      NFCXX_GCC_PASSTHROUGH=*) pt=1 ;;
      NFCXX_PATHB_FALLBACK=gcc) fb=1 ;;
      STUB_PATHB_STATUS=*) pbst=${e#STUB_PATHB_STATUS=} ;;
      NFCC_HOST_CC=*) host=${e#NFCC_HOST_CC=} ;;
      STUB_WIDE_LITERAL=*) wide=1 ;;
      NFCXX_PATHB_LOG=*) logf=1 ;;
      EDG_BUILD=*) edg=${e#EDG_BUILD=} ;;
      CUDA_HOME=*) cuda_home_env=${e#CUDA_HOME=} ;;
    esac
  done
  # NFCXX_PATHB_LOG, when the line sets it, is a file for each side: both logs must match too.
  # the bundling tool's state, as the shell sees it (build/nfcbundle missing, older than its source, or fresh)
  if [ ! -x "$PWD/build/nfcbundle" ]; then bst=missing
  elif [ tools/bundle/nfcbundle.cpp -nt "$PWD/build/nfcbundle" ]; then bst=stale
  else bst=fresh; fi
  # the CUDA wrapper's home (CUDA_HOME, if the line sets it); the port reads the home's files itself
  chome=${cuda_home_env:-}; serr=""
  cuenv=auto
  for e in "${envs[@]+"${envs[@]}"}"; do case $e in NFCXX_CUDA_DRIVER=*) cuenv=${e#NFCXX_CUDA_DRIVER=} ;; esac; done
  mach=$(uname -m)
  for e in "${envs[@]+"${envs[@]}"}"; do case $e in STUB_SHIM_ERROR=*) serr=${e#STUB_SHIM_ERROR=} ;; esac; done
  serrarg=(); [ -n "$serr" ] && serrarg=("--nfcc-shim-error=$serr")
  nf=0; for e in "${envs[@]+"${envs[@]}"}"; do case $e in STUB_NINJA_STATUS=*) [ "${e#STUB_NINJA_STATUS=}" = 0 ] || nf=1 ;; esac; done
  logA=""; logB=""; oenvs=("${envs[@]+"${envs[@]}"}")
  if [ "$logf" = 1 ]; then
    logA=$(mktemp); logB=$(mktemp)
    for i in "${!oenvs[@]}"; do case ${oenvs[$i]} in NFCXX_PATHB_LOG=*) oenvs[$i]="NFCXX_PATHB_LOG=$logA" ;; esac; done
  fi
  # the repository path is ROOT in the port's output; messages that bash prints itself get the same placeholder here
  oracle=$(env "${oenvs[@]+"${oenvs[@]}"}" tests/nfcc/option-state.sh "${args[@]}" 2>&1 | sed "s|$PWD|ROOT|g")
  port=$(ruby scripts/driver-loop.rb --nfcc-backend="$backend" --nfcc-passthrough=$pt \
           --nfcc-host-gnu-gcc=$host_gnu --nfcc-root=ROOT --nfcc-tmp=TMP --nfcc-cwd=ROOT \
           --nfcc-pathb-fallback=$fb --nfcc-pathb-status=$pbst \
           --nfcc-host=$host --nfcc-pathb-log="$logB" \
           --nfcc-bundle-tool=$bst --nfcc-ninja-fails=$nf \
           --nfcc-cuda-home="$chome" --nfcc-cuda-driver-env="$cuenv" --nfcc-machine="$mach" --nfcc-shim=SHIM "${serrarg[@]+"${serrarg[@]}"}" \
           --nfcc-dumpfullversion=13.3.0 --nfcc-host-version-line="cc (stub) 0" \
           --nfcc-os="$os" --nfcc-ldrt=LDRT --nfcc-edg-build=$edg --nfcc-wide-literal="$wide" \
           "${args[@]}" 2>&1)
  case $port in
    *"unported: "*) skipped=$((skipped + 1)); echo "skip $line (not ported yet)"; continue ;;
  esac
  logs_same=1
  if [ -n "$logA" ] && ! cmp -s "$logA" "$logB"; then logs_same=0; fi
  [ -n "$logA" ] && rm -f "$logA" "$logB"
  if [ "$oracle" = "$port" ] && [ $logs_same = 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $line"
    echo "  bash:  $(printf '%s' "$oracle" | tr '\n' '|')"
    echo "  ruby:  $(printf '%s' "$port" | tr '\n' '|')"
    [ $logs_same = 1 ] || echo "  the NFCXX_PATHB_LOG files differ"
  fi
done < tests/nfcc/loop-cases.txt
echo "$pass passed, $fail failed, $skipped not ported yet"
[ "$fail" = 0 ]
