#!/usr/bin/env bash
# GPU check of --obfuscate-kernels: a .cu with a plain and a template kernel, built through nfcxx-cuda and linked with
# the driver, must run with an exact result with and without the option; the obfuscated object and binary must not
# contain the original kernel names; the plain ones must. Also an obfuscated library (random seed) linked into a plain main.
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: obfuscate gpu: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
cat > "$out/obf.cu" <<'CU'
#include <cuda_runtime.h>
#include <stdio.h>
__global__ void vec_add_kn(const float *a, const float *b, float *c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}
template <int K>
__global__ void scale_tk(float *x, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) x[i] = x[i] * (float)K;
}
int main() {
  const int n = 1000;
  float ha[n], hb[n], hc[n];
  for (int i = 0; i < n; i++) { ha[i] = (float)i; hb[i] = 2.0f * i; }
  float *a, *b, *c;
  cudaMalloc(&a, n * 4); cudaMalloc(&b, n * 4); cudaMalloc(&c, n * 4);
  cudaMemcpy(a, ha, n * 4, cudaMemcpyHostToDevice);
  cudaMemcpy(b, hb, n * 4, cudaMemcpyHostToDevice);
  vec_add_kn<<<(n + 127) / 128, 128>>>(a, b, c, n);
  scale_tk<3><<<(n + 127) / 128, 128>>>(c, n);
  cudaMemcpy(hc, c, n * 4, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) if (hc[i] != (ha[i] + hb[i]) * 3.0f) bad++;
  printf("obf check: %d mismatches of %d\n", bad, n);
  return bad != 0;
}
CU
build() {  # build NAME OBFUSCATE(0|1): compiles and links through the driver, prints the run result
  local name=$1 obf=$2
  if [ "$obf" = 1 ]; then
    NFCXX_OBFUSCATE_KERNELS=1 NFCXX_OBFUSCATE_SEED=12345 "$root/scripts/nfcxx-cuda" -c "$out/obf.cu" -o "$out/$name.o" > "$out/$name.log" 2>&1
  else
    env -u NFCXX_OBFUSCATE_KERNELS "$root/scripts/nfcxx-cuda" -c "$out/obf.cu" -o "$out/$name.o" > "$out/$name.log" 2>&1
  fi
  "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart -o "$out/$name" >> "$out/$name.log" 2>&1
  LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$name"
}
for obf in 0 1; do
  name=plain; [ "$obf" = 1 ] && name=obf
  if run=$(build $name $obf); then echo "pass $name run: $run"; else echo "FAIL $name run: $run"; fail=1; fi
done
for n in vec_add_kn scale_tk; do
  strings "$out/obf.o" "$out/obf" > "$out/obf.strings"; strings "$out/plain.o" "$out/plain" > "$out/plain.strings"
  if grep -q "$n" "$out/obf.strings"; then echo "FAIL obfuscated object has $n"; fail=1; else echo "pass obfuscated object free of $n"; fi
  if grep -q "$n" "$out/plain.strings"; then echo "pass plain build has $n (check is meaningful)"; else echo "FAIL plain build lacks $n"; fail=1; fi
done
cat > "$out/lib.cu" <<'CU'
#include <cuda_runtime.h>
__global__ void lib_scale_kn(float *x, int n, float s) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) x[i] = x[i] * s;
}
extern "C" int lib_scale(float *host, int n, float s) {
  float *d; cudaMalloc(&d, n * 4);
  cudaMemcpy(d, host, n * 4, cudaMemcpyHostToDevice);
  lib_scale_kn<<<(n + 127) / 128, 128>>>(d, n, s);
  cudaMemcpy(host, d, n * 4, cudaMemcpyDeviceToHost);
  cudaFree(d);
  return cudaGetLastError() == cudaSuccess ? 0 : 1;
}
CU
cat > "$out/main2.cu" <<'CU'
extern "C" int lib_scale(float *host, int n, float s);
int main() {
  const int n = 512; float h[n];
  for (int i = 0; i < n; i++) h[i] = (float)i;
  int rc = lib_scale(h, n, 2.5f);
  int bad = 0; for (int i = 0; i < n; i++) if (h[i] != (float)i * 2.5f) bad++;
  return rc != 0 || bad != 0;
}
CU
if NFCXX_OBFUSCATE_KERNELS=1 "$root/scripts/nfcxx-cuda" -c "$out/lib.cu" -o "$out/lib.o" > "$out/lib.log" 2>&1 \
   && "$root/scripts/nfcxx-cuda" -c "$out/main2.cu" -o "$out/main2.o" > "$out/main2.log" 2>&1 \
   && "$root/nfcxx" "$out/main2.o" "$out/lib.o" -L"$cuda/lib64" -lcudart -o "$out/libtest" >> "$out/main2.log" 2>&1 \
   && LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/libtest"; then
  echo "pass obfuscated library linked into plain main"
else
  echo "FAIL obfuscated library linked into plain main"; fail=1
fi
exit $fail
