#!/usr/bin/env bash
# The Ruby port of nfcxx's argument loop (scripts/nfcxx-loop.rb) must leave the same state, and fail with the same message, as
# nfcxx's own loop (tests/nfcxx/option-state.sh) for every argument list of tests/nfcxx/loop-cases.txt. A case the port refuses
# as "unported" is counted, not compared.
cd "$(dirname "$0")/../.."
pass=0; fail=0; skipped=0
ldav=""
# The facts of the CUDA wrap (scripts/cuda-driver-wrap.sh) for the toolkits given: the headers that exist, the lib64
# directories that exist, and the CUDART_VERSION of cuda_runtime_api.h (the wrap's own sed), as the port's options.
cuda_facts() {
  local h f v
  for h in "$@"; do
    for f in cuda.h cudaTypedefs.h cuda_runtime_api.h; do
      if [ -f "$h/include/$f" ]; then echo "--nfcxx-cuda-file=$h/include/$f"; fi
    done
    if [ -d "$h/lib64" ]; then echo "--nfcxx-cuda-dir=$h/lib64"; fi
    v=$(sed -nE 's/^#define[ \t]+CUDART_VERSION[ \t]+([0-9]+).*/\1/p' "$h/include/cuda_runtime_api.h" 2>/dev/null | head -1)
    if [ -n "$v" ]; then echo "--nfcxx-cuda-rtv=$h/include/cuda_runtime_api.h=$v"; fi
  done
}
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  read -r -a words <<< "$line"
  # leading NAME=VALUE words are the environment of the line (the variables nfcxx's setup reads, CUDA_HOME, and the CUDA_TEST_*
  # stubs of the oracle): both sides get them
  envs=(); args=()
  for w in "${words[@]}"; do
    if [ ${#args[@]} -eq 0 ] && [[ $w =~ ^(NFCXX_[A-Z_]+|TMPDIR|CUDA_HOME|ROCM|CUDA_TEST_[A-Z_]+)= ]]; then envs+=("$w"); else args+=("$w"); fi
  done
  nenv=(); for e in "${envs[@]+"${envs[@]}"}"; do nenv+=("--nfcxx-env=$e"); done
  # the CUDA wrap's facts: the toolkits of the fixtures and the system's, and the line's CUDA_HOME; the stubs of the machine and
  # the shim (the oracle's CUDA_TEST_MACHINE and CUDA_TEST_SHIM, given to the port as its options)
  cudahomes=(tests/nfcxx/cuda-fixtures tests/nfcxx/cuda-fixtures/old tests/nfcxx/cuda-fixtures/none /usr/local/cuda); cudaopts=()
  for e in "${envs[@]+"${envs[@]}"}"; do
    case $e in
      CUDA_HOME=?*) cudahomes+=("${e#CUDA_HOME=}") ;;
      CUDA_TEST_MACHINE=*) cudaopts+=("--nfcxx-machine=${e#CUDA_TEST_MACHINE=}") ;;
      CUDA_TEST_SHIM=*) cudaopts+=("--nfcxx-shim=${e#CUDA_TEST_SHIM=}") ;;
    esac
  done
  mapfile -t cudafacts < <(cuda_facts "${cudahomes[@]}")
  nenv+=("${cudafacts[@]}" "${cudaopts[@]}")
  tmpdir=${TMPDIR-}; for e in "${envs[@]+"${envs[@]}"}"; do case $e in TMPDIR=*) tmpdir=${e#TMPDIR=} ;; esac; done
  oracle=$(env "${envs[@]+"${envs[@]}"}" tests/nfcxx/option-state.sh "${args[@]}" 2>&1); ostatus=$?
  port=$(ruby scripts/nfcxx-loop.rb --ld-available="$ldav" --nfcxx-uid="$(id -u)" --nfcxx-tmpdir="$tmpdir" \
           "${nenv[@]+"${nenv[@]}"}" "${args[@]}" 2>&1); pstatus=$?
  case $port in
    *"unported: "*) skipped=$((skipped + 1)); echo "skip $line (not ported yet)"; continue ;;
  esac
  if [ "$oracle" = "$port" ] && [ "$ostatus" = "$pstatus" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $line"
    echo "  bash:  (status $ostatus) $(printf '%s' "$oracle" | tr '\n' '|' | cut -c1-400)"
    echo "  ruby:  (status $pstatus) $(printf '%s' "$port" | tr '\n' '|' | cut -c1-400)"
  fi
done < tests/nfcxx/loop-cases.txt
echo "$pass passed, $fail failed, $skipped not ported yet"
[ "$fail" = 0 ]
