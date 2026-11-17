#!/bin/bash
# scripts/nfcxx-eccp-env.rb plan must export the eccp environment as the driver's loop does (verbatim below), for the element shapes
# the planner gives: NAME=VALUE, an empty value, a value with spaces, a value with = and $, and a bare NAME; and an empty list.
#   bash tests/driver-eccp-env/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
probe() { printf '%s\n' "${PROBE_NAMES[@]}" | while read -r n; do printf '%s=[%s]\n' "$n" "$(printenv "$n" 2>/dev/null || echo unset)"; done; }
cases=(
  "NFCXX_A=1"
  "NFCXX_B="
  "NFCXX_C=a b  c"
  "NFCXX_D=x=y\$HOME"
  "NFCXX_E"
  "NFCXX_A=1 NFCXX_B=2"
  ""
)
for cs in "${cases[@]}"; do
  eccp_envs=()
  for w in $cs; do eccp_envs+=("$w"); done
  [ "$cs" = "NFCXX_C=a b  c" ] && eccp_envs=("NFCXX_C=a b  c")
  [ "$cs" = "NFCXX_D=x=y\$HOME" ] && eccp_envs=("NFCXX_D=x=y\$HOME")
  envs=$(IFS=$'\x1f'; echo "${eccp_envs[*]-}")
  PROBE_NAMES=(NFCXX_A NFCXX_B NFCXX_C NFCXX_D NFCXX_E)
  want=$( env -u NFCXX_A -u NFCXX_B -u NFCXX_C -u NFCXX_D -u NFCXX_E bash -c "$(declare -p eccp_envs PROBE_NAMES 2>/dev/null); $(declare -f probe); ( for e in \${eccp_envs[@]+\"\${eccp_envs[@]}\"}; do export \"\$e\"; done; probe )" )
  got=$( env -u NFCXX_A -u NFCXX_B -u NFCXX_C -u NFCXX_D -u NFCXX_E bash -c "$(declare -p PROBE_NAMES); $(declare -f probe); ( eval \"\$(ruby '$repo/scripts/nfcxx-eccp-env.rb' plan envs='$envs')\"; probe )" )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL [$cs]"; echo "  bash: $want"; echo "  ruby: $got"; fi
done
echo "driver-eccp-env: $pass passed, $fail failed"
[ $fail = 0 ]
