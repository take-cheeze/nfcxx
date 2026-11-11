#!/usr/bin/env bash
# The device kernels of tests/gpu (their golden Path B IR) on an AMD GPU: tools/pathb-amdgpu-emit lowers each to amdgcn
# LLVM IR, ROCm's clang makes the code object, and the CUDA launchers of tests/gpu run it unchanged through the HIP
# runtime (cuda_runtime.h here maps their calls). Each launcher checks the results on the host. Mutants of the IR must
# fail. docs/notes/gpu.md, "AMD GPUs (ROCm)".
# Env: ROCM (default /opt/rocm; the HIP headers and runtime), NFCXX_AMDGPU_ARCH and NFCXX_AMDGPU_CLANG (scripts/amdgpu-env.sh).
# Skips (exit 0) without a clang with the amdgcn target, the HIP headers and runtime, or an AMD GPU.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
rocm=${ROCM:-/opt/rocm}
. "$root/scripts/amdgpu-env.sh"
arch=$(amdgpu_arch) || arch=""
clang=$(amdgpu_clang) || clang=""
if [ -z "$clang" ] || [ ! -f "$rocm/include/hip/hip_runtime_api.h" ] || [ ! -e "$rocm/lib/libamdhip64.so" ] || [ -z "$arch" ]; then
  echo "SKIP: gpu amd: needs a clang with the amdgcn target, the HIP headers and runtime, and an AMD GPU"; exit 0
fi
ninja -C "$root/tools/pathb-amdgpu-emit" > /dev/null || exit 1
emit=$root/build/pathb-amdgpu-emit
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
dev=$root/tests/gpu/device

hsaco() {  # hsaco IR NAME [EMIT-OPTIONS...]: NAME.hsaco from the IR, or fails
  local ir=$1 name=$2; shift 2
  "$emit" "$@" "$ir" > "$out/$name.ll" || return 1
  "$clang" -target amdgcn-amd-amdhsa -mcpu="$arch" -O2 -nogpulib "$out/$name.ll" -o "$out/$name.hsaco"
}
launcher() {  # launcher SRC [NAME]: builds the CUDA launcher SRC against the HIP shim, as NAME (default: its basename)
  local b=${2:-$(basename "$1" .c)}
  [ -x "$out/$b" ] && return 0
  gcc -O2 -w -I"$here" -I"$rocm/include" "$1" -o "$out/$b" -L"$rocm/lib" -lamdhip64 -Wl,-rpath,"$rocm/lib"
}
check() {  # check LABEL CMD...: the command must succeed
  local label=$1; shift
  if "$@" > "$out/run.log" 2>&1; then echo "run $label: ok"
  else echo "run $label: FAIL"; sed 's/^/  /' "$out/run.log" | tail -5; fail=1; fi
}
mutant() {  # mutant LABEL CMD...: the command must fail
  local label=$1; shift
  if "$@" > /dev/null 2>&1; then echo "mutant $label: FAIL (not caught)"; fail=1; else echo "mutant $label: caught"; fi
}

echo "arch: $arch"
hsaco "$root/tests/gpu/mul2.ir" mul2 && launcher "$root/tests/gpu/launch.c" launch_mul2 && check mul2 "$out/launch_mul2" "$out/mul2.hsaco"
hsaco "$dev/vecadd.ir" vecadd && launcher "$dev/launch.c" && check vecadd "$out/launch" "$out/vecadd.hsaco" _Z6vecAddPfS_S_i
sed 's/(fadd float %18 %22)/(fsub float %18 %22)/' "$dev/vecadd.ir" > "$out/vecadd_mut.ir"
hsaco "$out/vecadd_mut.ir" vecadd_mut && mutant "vecadd (add -> sub)" "$out/launch" "$out/vecadd_mut.hsaco" _Z6vecAddPfS_S_i
hsaco "$dev/helper.ir" helper && launcher "$dev/launch_helper.c" && check helper "$out/launch_helper" "$out/helper.hsaco"
hsaco "$dev/memory2.ir" memory2 && launcher "$dev/launch_memory2.c" && check memory2 "$out/launch_memory2" "$out/memory2.hsaco"
hsaco "$dev/nonnull.ir" nonnull && launcher "$dev/launch_nonnull.c" &&
  check "nonnull ok" "$out/launch_nonnull" "$out/nonnull.hsaco" _Z13load_plus_onePKiPi ok
hsaco "$dev/shared.ir" shared && launcher "$dev/launch_shared.c" && check shared "$out/launch_shared" "$out/shared.hsaco" _Z13reverse_blockPKfPf
hsaco "$dev/struct_abi.ir" struct_abi && launcher "$dev/launch_struct_abi.c" && check struct_abi "$out/launch_struct_abi" "$out/struct_abi.hsaco"
hsaco "$dev/switch.ir" switch && launcher "$dev/launch_switch.c" && check switch "$out/launch_switch" "$out/switch.hsaco" _Z8classifyPKiPii
hsaco "$dev/atomics.ir" atomics && launcher "$dev/launch_atomics.c" &&
  check atomics "$out/launch_atomics" "$out/atomics.hsaco" _Z7atomicsPKiPiPfS1_S1_S1_S1_i
hsaco "$dev/warp.ir" warp && launcher "$dev/launch_warp.c" && check warp "$out/launch_warp" "$out/warp.hsaco" _Z8warp_opsPKiPiPfPjS1_i
# The first xor shuffle as an up shuffle, and any as all: the launcher's checks must see both.
sed '0,/__nfcxx_shfl_xor_sync_i/s//__nfcxx_shfl_up_sync_i/' "$dev/warp.ir" > "$out/warp_mut1.ir"
hsaco "$out/warp_mut1.ir" warp_mut1 && mutant "warp shuffle (xor -> up)" "$out/launch_warp" "$out/warp_mut1.hsaco" _Z8warp_opsPKiPiPfPjS1_i
sed 's/__nfcxx_any_sync/__nfcxx_all_sync/' "$dev/warp.ir" > "$out/warp_mut2.ir"
hsaco "$out/warp_mut2.ir" warp_mut2 && mutant "warp vote (any -> all)" "$out/launch_warp" "$out/warp_mut2.hsaco" _Z8warp_opsPKiPiPfPjS1_i
# A construct the emitter does not lower is refused with exit 3.
printf '(ir-module "r.cpp" (layout (int 4)))\n(function "k"\n  (ret void)\n  (params)\n  (ptx-asm "trap;")\n  (return))\n' > "$out/refuse.ir"
rc=0; "$emit" "$out/refuse.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 3 ]; then echo "refused inline PTX: ok"; else echo "refused inline PTX: FAIL (exit $rc)"; fail=1; fi
exit $fail
