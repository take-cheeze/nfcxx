#!/usr/bin/env bash
# Compile every .cu file of the repository for the AMD GPU target (NFCXX_CUDA_TARGET=amdgpu, docs/notes/gpu.md, "AMD GPUs
# (ROCm)"), and report: ok (the object builds, device code included), refused (a construct the AMD path does not lower, by
# design: inline PTX, indirect calls, device-wide CUB, ...), or fail (anything else, with the first error). This is a compile
# sweep, not a run: most of these files need an NVIDIA GPU to run. The results are in OUT/results.txt, one line per file.
# Env: OUT (default: a temporary directory), JOBS (default 8), NFCXX_AMDGPU_ARCH and NFCXX_AMDGPU_CLANG (scripts/amdgpu-env.sh),
# ROCM (the HIP headers, default /opt/rocm), EDG_BUILD / EDG_BASE (the EDG build; it needs the HIP headers' fix, docs/notes/gpu.md).
# Skips (exit 0) without a clang with the amdgcn target, the HIP headers, or an AMD GPU.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
rocm=${ROCM:-/opt/rocm}
. "$root/scripts/amdgpu-env.sh"
arch=$(amdgpu_arch) || arch=""
if ! amdgpu_clang > /dev/null || [ ! -f "$rocm/include/hip/hip_runtime_api.h" ] || [ -z "$arch" ]; then
  echo "SKIP: cuda amdgpu sweep: needs a clang with the amdgcn target, the HIP headers, and an AMD GPU"; exit 0
fi
out=${OUT:-$(mktemp -d)}
mkdir -p "$out/work"
one() {  # one FILE: compile FILE, print "STATUS|rc|FILE|first error"
  local f=$1 id d rc st msg
  id=$(echo "$f" | tr / _); d=$out/work/$id; mkdir -p "$d"
  (cd "$d" && TMPDIR=$d NFCXX_BACKEND=gcc NFCXX_CUDA_TARGET=amdgpu NFCXX_AMDGPU_ARCH=$arch timeout 900 \
     "$root/nfcxx" -c -std=c++17 -I"$root/lib/hip" -I"$rocm/include" -I"$(dirname "$root/$f")" "$root/$f" -o "$d/out.o" > "$d/log" 2>&1)
  rc=$?
  case $rc in 0) st=ok ;; 3) st=refused ;; 124) st=timeout ;; *) st=fail ;; esac
  msg=$(grep -m1 -E "refused:|bad IR|error:|nfcxx:|catastrophic|cannot open" "$d/log" | tr -d '\n' | cut -c1-180)
  echo "$st|$rc|$f|$msg"
}
export -f one; export out root rocm arch
(cd "$root" && find tests -name '*.cu' | sort) | xargs -P "${JOBS:-8}" -I{} bash -c 'one "$@"' _ {} > "$out/results.txt"
echo "results: $out/results.txt"
cut -d'|' -f1 "$out/results.txt" | sort | uniq -c | sed 's/^/  /'
exit 0
