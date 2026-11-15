#!/bin/bash
# Differential test of scripts/amdgpu-env.rb against tests/amdgpu-env/oracle.sh (the bash original). Each case runs one
# function both ways with the same environment and the same fake tools on PATH; the stdout and the exit status must match.
# The architecture from KFD is read only when this host has a KFD topology (the case is skipped otherwise, since the
# machine decides it). Lines of the form "CASE | FUNCTION".
#
#   bash tests/amdgpu-env/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/oracle.sh
ruby_cli=$repo/scripts/amdgpu-env.rb
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/amdclang" "$work/plainclang" "$work/rocm/llvm/bin" "$work/empty"

# clang: prints the amdgcn target only when it is the one named AMDCLANG_TARGETS in its directory
printf '#!/bin/bash\n[ "$1" = --print-targets ] && { echo "Registered Targets:"; echo "  amdgcn - AMD GCN GPUs"; echo "  x86-64 - 64-bit X86"; }\n' > "$work/amdclang/clang"
printf '#!/bin/bash\n[ "$1" = --print-targets ] && { echo "Registered Targets:"; echo "  x86-64 - 64-bit X86"; }\n' > "$work/plainclang/clang"
printf '#!/bin/bash\nexit 0\n' > "$work/rocm/llvm/bin/clang"
chmod +x "$work"/amdclang/clang "$work"/plainclang/clang "$work/rocm/llvm/bin/clang"

kfd=0; [ -d /sys/class/kfd/kfd/topology/nodes ] && kfd=1

cases=(
  "arch-override | NFCXX_AMDGPU_ARCH=gfx1151 | amdgpu_arch"
  "clang-override | NFCXX_AMDGPU_CLANG=/opt/x/clang | amdgpu_clang"
  "clang-on-path | PATH=$work/amdclang:/usr/bin:/bin | amdgpu_clang"
  "clang-no-amdgcn-rocm | PATH=$work/plainclang:/usr/bin:/bin ROCM=$work/rocm | amdgpu_clang"
  "clang-none | PATH=$work/empty:/usr/bin:/bin ROCM=$work/empty | amdgpu_clang"
  "clang-rocm-default-missing | PATH=$work/empty:/usr/bin:/bin ROCM=$work/nope | amdgpu_clang"
  "arch-no-gpu | PATH=$work/empty:/usr/bin:/bin | amdgpu_arch"
)

pass=0; fail=0; skip=0
for c in "${cases[@]}"; do
  name=${c%%|*}; name=${name// /}
  rest=${c#*|}; envs=${rest%%|*}; fn=${rest#*|}; envs=${envs# }; fn=${fn# }
  if [ "$name" = arch-no-gpu ] && [ "$kfd" = 1 ]; then skip=$((skip + 1)); continue; fi
  # the environment: the named variables only; PATH is the case's, else ruby's directory and the system's
  rubydir=$(dirname "$(command -v ruby)"); ruby_bin=$(command -v ruby)
  case $envs in *PATH=*) ;; *) envs="$envs PATH=$rubydir:/usr/bin:/bin" ;; esac
  # shellcheck disable=SC2086
  a=$(cd "$repo" && env -i HOME="$work" $envs bash -c 'source "$1"; shift; "$@"' bash "$oracle" $fn 2>/dev/null); sa=$?
  # shellcheck disable=SC2086
  b=$(cd "$repo" && env -i HOME="$work" $envs "$ruby_bin" "$ruby_cli" $fn 2>/dev/null); sb=$?
  if [ "$a" = "$b" ] && [ "$sa" = "$sb" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$name] $fn"
    echo "  bash ($sa): $a"
    echo "  ruby ($sb): $b"
  fi
done
echo "amdgpu-env: $pass passed, $fail failed, $skip skipped (this host has a KFD topology)"
[ $fail = 0 ]
