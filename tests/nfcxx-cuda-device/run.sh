#!/usr/bin/env bash
# The check of scripts/nfcxx-cuda-device.rb against nfcxx's own CUDA device build. For each case of
# tests/nfcxx-cuda-device/cases.txt, the case's tree is made (stub tools, a toolkit, a -I directory, a cache entry), the port
# prints the commands for it, and oracle.sh (nfcxx's functions with the tools stubbed) prints the commands the bash runs on
# the same tree and environment. The two must print the same lines in the same order, with the same status. A case the port
# refuses as "unported" (exit 3) is counted, not compared.
#   tests/nfcxx-cuda-device/run.sh     runs every case; exit 1 on a mismatch
cd "$(dirname "$0")/../.." || exit 2
here=tests/nfcxx-cuda-device
src=$PWD/$here/fixtures/mul2.cu
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
pass=0; fail=0; skipped=0

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

setup() {  # setup W HAVE: the case's tree: nfcxx's root (W/root) with stub tools, the toolkit (W/cuda, W/nocuda), a -I directory (W/inc)
  local w=$1 have=$2 h
  rm -rf "$w"
  mkdir -p "$w/root/build" "$w/root/scripts" "$w/root/bin" "$w/tmp" "$w/home" "$w/cuda/include" "$w/cuda/bin" \
           "$w/nocuda/bin" "$w/inc" "$w/cache" || exit 2
  cp "$here"/fixtures/cuda/include/* "$w/cuda/include/" || exit 2
  cp "$here"/fixtures/inc/* "$w/inc/" || exit 2
  cp scripts/amdgpu-env.sh "$w/root/scripts/" || exit 2
  cp "$here/tool-stub" "$w/root/build/cuda-rewrite" || exit 2
  cp "$here/tool-stub" "$w/root/scripts/pathb-dump" || exit 2
  cp "$here/tool-stub" "$w/root/bin/clang" || exit 2
  cp "$here/tool-stub" "$w/cuda/bin/ptxas" || exit 2
  cp "$here/tool-stub" "$w/cuda/bin/ptxas-alt" || exit 2
  cp "$here/tool-stub" "$w/nocuda/bin/ptxas" || exit 2
  for h in $have; do
    case $h in
      ptx-emit) cp "$here/tool-stub" "$w/root/build/pathb-ptx-emit" ;;
      amd-emit) cp "$here/tool-stub" "$w/root/build/pathb-amdgpu-emit" ;;
      cache-hit) mkdir -p "$w/cache/cu-device/abc123/groups" && : > "$w/cache/cu-device/abc123/ir" ;;
      *) echo "run.sh: unknown tree entry $h" >&2; exit 2 ;;
    esac
  done
}

while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  IFS='|' read -r name envs have kernels groups args <<< "$line"
  name=$(trim "$name"); envs=$(trim "$envs"); have=$(trim "$have")
  kernels=$(trim "$kernels"); groups=$(trim "$groups"); args=$(trim "$args")
  for v in envs have kernels groups args; do [ "${!v}" = - ] && printf -v "$v" '%s' ''; done
  w=$work/case
  envs=${envs//@W@/$w}; args=${args//@W@/$w}
  kernels=${kernels//,/ }; groups=${groups//,/ }
  read -r -a envw <<< "$envs"
  read -r -a argw <<< "$args"
  allenv=(HOME="$w/home" CUDA_HOME="$w/cuda" "${envw[@]}")
  nenv=(); for e in "${allenv[@]}"; do nenv+=("--nfcxx-env=$e"); done
  kargs=(); for k in $kernels; do kargs+=("--kernel=$k"); done
  gargs=(); for g in $groups; do gargs+=("--group=$g"); done

  # the port, on the tree as it is before any tool runs
  setup "$w" "$have"
  mapfile -t facts < <({ find "$w" -type f -printf '--nfcxx-file=%p\n'; find "$w" -type d -printf '--nfcxx-dir=%p\n'; })
  pout=$(ruby scripts/nfcxx-cuda-device.rb --root="$w/root" --tmp="$w/tmp" "${nenv[@]}" "${facts[@]}" \
           "${kargs[@]}" "${gargs[@]}" "${argw[@]}" "$src" 2>&1); pst=$?
  if [ "$pst" = 3 ]; then
    skipped=$((skipped + 1)); echo "skip $name (${pout#unported: })"; continue
  fi

  # the oracle, on a fresh tree of the same shape
  setup "$w" "$have"
  oout=$(env -i PATH="$PATH" "${allenv[@]}" CU_TEST_ROOT="$w/root" CU_TEST_TMP="$w/tmp" CU_TEST_LOG="$w/oracle.log" \
           CU_TEST_KERNELS="$kernels" CU_TEST_GROUPS="$groups" \
           bash "$here/oracle.sh" "$w/root" "$src" "${argw[@]}" 2>&1); ost=$?

  # the PID of a cache store's temporary directory is not part of the plan
  pnorm=$(printf '%s\n' "$pout" | sed 's/\.tmp\.[0-9][0-9]*/.tmp.PID/g')
  onorm=$(printf '%s\n' "$oout" | sed 's/\.tmp\.[0-9][0-9]*/.tmp.PID/g')
  if [ "$pst" = "$ost" ] && [ "$pnorm" = "$onorm" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name (port status $pst, oracle status $ost)"
    diff <(printf '%s\n' "$pnorm") <(printf '%s\n' "$onorm") | head -12 | sed 's/^/  /'
  fi
done < "$here/cases.txt"
echo "$pass passed, $fail failed, $skipped unported"
[ "$fail" = 0 ]
