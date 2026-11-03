#!/usr/bin/env bash
# A .cu file on an AMD GPU (NFCXX_CUDA_TARGET=amdgpu, docs/notes/gpu.md, "AMD GPUs (ROCm)"): tests/cuda/mul2.cu compiled by
# nfcxx with the CUDA runtime on HIP (lib/hip/cuda_runtime.h). Its kernel is lowered to amdgcn by tools/pathb-amdgpu-emit,
# and ROCm's clang makes the code object. The program checks 1000 results against the host, so it fails if the kernel does
# not run. A mutant (the kernel multiplies by 3) must fail. Needs ROCm (clang, HIP headers and runtime) and an AMD GPU,
# and the EDG front end that accepts HIP's headers (docs/notes/gpu.md). Skips (exit 0) without them.
# Env: NFCXX_AMDGPU_ARCH (default: the first GPU rocminfo lists), ROCM (default /opt/rocm).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
rocm=${ROCM:-/opt/rocm}
arch=${NFCXX_AMDGPU_ARCH:-$("$rocm/bin/rocminfo" 2>/dev/null | awk '/Name: *gfx[0-9a-f]+ *$/ {print $2; exit}')}
if [ ! -x "$rocm/llvm/bin/clang" ] || [ ! -f "$rocm/include/hip/hip_runtime_api.h" ] || [ ! -e "$rocm/lib/libamdhip64.so" ] || [ -z "$arch" ]; then
  echo "SKIP: cuda amdgpu: needs ROCm (clang, HIP headers and runtime) and an AMD GPU"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export NFCXX_BACKEND=gcc TMPDIR=$out
build() {  # build SRC OUTBIN: the .cu file on the AMD target
  NFCXX_CUDA_TARGET=amdgpu NFCXX_AMDGPU_ARCH=$arch "$root/nfcxx" -std=c++17 -I"$root/lib/hip" -I"$rocm/include" \
    -L"$rocm/lib" -lamdhip64 -Wl,-rpath,"$rocm/lib" "$1" -o "$2" 2>"$2.log"
}
fail=0
if build "$here/../mul2.cu" "$out/mul2"; then
  if "$out/mul2" > "$out/run.log" 2>&1 && grep -q "mul2: 1000 elements, 0 mismatches" "$out/run.log"; then
    echo "run mul2 ($arch): ok"
  else
    echo "run mul2 ($arch): FAIL"; sed 's/^/  /' "$out/run.log" | tail -5; fail=1
  fi
else
  echo "build mul2 ($arch): FAIL"; grep -m3 " error" "$out/mul2.log" | sed 's/^/  /'; exit 1
fi

# The mutant: the kernel's multiplier is 3, the host's expected value stays 2 * h[i].
sed 's/b\[i\] = a\[i\] \* 2;/b[i] = a[i] * 3;/' "$here/../mul2.cu" > "$out/mul2_mut.cu"
if cmp -s "$here/../mul2.cu" "$out/mul2_mut.cu"; then echo "mutant mul2: FAIL (the substitution did not apply)"; exit 1; fi
if build "$out/mul2_mut.cu" "$out/mul2_mut" && "$out/mul2_mut" > /dev/null 2>&1; then
  echo "mutant mul2: FAIL (not caught)"; fail=1
else
  echo "mutant mul2: caught"
fi
exit $fail
