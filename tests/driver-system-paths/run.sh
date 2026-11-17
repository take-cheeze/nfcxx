#!/bin/bash
# scripts/nfcxx-system-paths.rb plan must leave NFCXX_SYSTEM_PATHS (its value, and whether it is exported) as the driver's two
# lines do (verbatim below), for each CUDA_HOME, NFCXX_SYSTEM_PATHS, NFCXX_CUDA_TARGET and ROCM setting.
#   bash tests/driver-system-paths/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
root=/case/root
pass=0; fail=0
opt() { [ "$1" = unset ] && return 0; echo "$1"; }
state() { if [ -n "${NFCXX_SYSTEM_PATHS+x}" ]; then printf 'set=[%s] exported=%s\n' "$NFCXX_SYSTEM_PATHS" "$(env | grep -c '^NFCXX_SYSTEM_PATHS=')"; else echo "unset"; fi; }
for cuda in unset "" /cuda; do for sp in unset "" /x; do for tgt in unset nvidia amdgpu; do for rocm in unset /r; do
  # the bash, verbatim (the driver's variables and root)
  want=$( env -u CUDA_HOME -u NFCXX_SYSTEM_PATHS -u NFCXX_CUDA_TARGET -u ROCM \
    ${cuda:+} $( [ "$cuda" != unset ] && echo "CUDA_HOME=$cuda" ) $( [ "$sp" != unset ] && echo "NFCXX_SYSTEM_PATHS=$sp" ) \
    $( [ "$tgt" != unset ] && echo "NFCXX_CUDA_TARGET=$tgt" ) $( [ "$rocm" != unset ] && echo "ROCM=$rocm" ) \
    PATH="$PATH" bash -c "root='$root'; [ -n \"\${CUDA_HOME:-}\" ] && export NFCXX_SYSTEM_PATHS=\"\$CUDA_HOME\${NFCXX_SYSTEM_PATHS:+:\$NFCXX_SYSTEM_PATHS}\"
[ \"\${NFCXX_CUDA_TARGET:-nvidia}\" = amdgpu ] && export NFCXX_SYSTEM_PATHS=\"\$root/lib/hip:\${ROCM:-/opt/rocm}/include\${NFCXX_SYSTEM_PATHS:+:\$NFCXX_SYSTEM_PATHS}\"
$(declare -f state); state" )
  got=$( env -u CUDA_HOME -u NFCXX_SYSTEM_PATHS -u NFCXX_CUDA_TARGET -u ROCM \
    $( [ "$cuda" != unset ] && echo "CUDA_HOME=$cuda" ) $( [ "$sp" != unset ] && echo "NFCXX_SYSTEM_PATHS=$sp" ) \
    $( [ "$tgt" != unset ] && echo "NFCXX_CUDA_TARGET=$tgt" ) $( [ "$rocm" != unset ] && echo "ROCM=$rocm" ) \
    PATH="$PATH" bash -c "$(declare -f state); eval \"\$(ruby '$repo/scripts/nfcxx-system-paths.rb' plan root='$root')\"; state" )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL cuda=$cuda sp=$sp tgt=$tgt rocm=$rocm"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done; done; done
echo "driver-system-paths: $pass passed, $fail failed"
[ $fail = 0 ]
