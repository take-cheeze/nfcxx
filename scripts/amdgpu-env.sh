# Sourced (not run): finds the AMD GPU's architecture and an LLVM clang that can compile for amdgcn, for nfcxx's AMD GPU
# path (docs/notes/gpu.md, "AMD GPUs (ROCm)"). Neither needs a ROCm tool: the architecture comes from the kernel driver's
# topology (KFD), and the compiler is any clang with the amdgcn target (upstream LLVM has it), else ROCm's clang. The HIP
# runtime (libamdhip64) is still needed to run a program.
#
#   amdgpu_arch                 prints the first GPU's gfx name (gfx1151), or fails when there is no AMD GPU
#   amdgpu_clang                prints a clang that targets amdgcn, or fails
#
# Overrides: NFCXX_AMDGPU_ARCH (the architecture), NFCXX_AMDGPU_CLANG (the compiler), ROCM (ROCm's root, default /opt/rocm).

amdgpu_arch() {
  if [ -n "${NFCXX_AMDGPU_ARCH:-}" ]; then printf '%s\n' "$NFCXX_AMDGPU_ARCH"; return 0; fi
  local node v
  for node in /sys/class/kfd/kfd/topology/nodes/*/; do
    # KFD's topology keeps the value in the node's properties file ("gfx_target_version 110501"); older kernels had a file.
    v=$(awk '$1 == "gfx_target_version" {print $2}' "$node/properties" 2>/dev/null)
    [ -n "$v" ] || v=$(cat "$node/gfx_target_version" 2>/dev/null) || continue
    # gfx_target_version is major * 10000 + minor * 100 + stepping: 110501 is gfx1151 (stepping 1, as one hex digit).
    if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
      printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
      return 0
    fi
  done
  return 1
}

amdgpu_clang() {
  if [ -n "${NFCXX_AMDGPU_CLANG:-}" ]; then printf '%s\n' "$NFCXX_AMDGPU_CLANG"; return 0; fi
  local c
  for c in clang clang-21 clang-20 clang-19 clang-18; do
    if command -v "$c" > /dev/null 2>&1 && "$c" --print-targets 2>/dev/null | grep -q '^ *amdgcn '; then
      command -v "$c"; return 0
    fi
  done
  local rocm=${ROCM:-/opt/rocm}
  if [ -x "$rocm/llvm/bin/clang" ]; then printf '%s\n' "$rocm/llvm/bin/clang"; return 0; fi
  return 1
}
