// Device functions a kernel calls, compiled into it (pathb-ptx-emit --inline=device, the driver's NFCXX_INLINE_DEVICE=1)
// and as calls: the results are the host's. The helpers cover the shapes the inliner takes: several returns, a loop, a
// pointer argument, a void helper, a helper that calls a helper, a local array in the frame, and a warp shuffle.
#include <cuda_runtime.h>
#include <stdio.h>

__device__ __forceinline__ int pick(int x) {
  if (x < 0) return -x;
  if (x > 100) return 100;
  return x * 2;
}

__device__ __forceinline__ float sum_to(int n) {
  float s = 0.0f;
  for (int i = 1; i <= n; i++) s += (float)i;
  return s;
}

__device__ __forceinline__ void bump(int *p, int by) { *p += by; }

__device__ int twice(int x) { return pick(x) + pick(x); }

__device__ int table_sum(int seed) {
  int t[4];
  for (int i = 0; i < 4; i++) t[i] = seed + i;
  return t[0] + t[1] + t[2] + t[3];
}

struct Pair {
  int a;
  float b;
};

// a struct result (sret) and a struct argument (byval): the callee's changes to its copy stay in the copy
__device__ __forceinline__ Pair make_pair(int x) {
  Pair p;
  p.a = x;
  p.b = x * 0.5f;
  return p;
}

// reads its struct only: the inlined body reads the caller's struct, and writes nothing else
__device__ __forceinline__ int sum_pair(Pair p) { return p.a + (int)p.b; }

__device__ __forceinline__ int bump_copy(Pair p) {
  p.a += 1;
  return p.a + (int)p.b;
}

__device__ __forceinline__ int warp_sum(int v) {
  for (int off = 16; off > 0; off >>= 1) v += __shfl_xor_sync(0xffffffffu, v, off);
  return v;
}

__global__ void k(int *o, const int *in) {
  int i = threadIdx.x;
  o[i] = pick(in[i]) + twice(in[i]);
  bump(&o[i], 7);
  o[32 + i] = (int)sum_to(in[i]) + table_sum(in[i]);
  o[64 + i] = warp_sum(in[i]);
  Pair p = make_pair(in[i]);
  o[96 + i] = bump_copy(p) + p.a;
  o[128 + i] = sum_pair(p) * 3;
}

static int host_pick(int x) { return x < 0 ? -x : (x > 100 ? 100 : x * 2); }

int main() {
  const int n = 32;
  int h_in[n], h[160], want = 0;
  for (int i = 0; i < n; i++) h_in[i] = (i * 37) % 211 - 60;
  int *d_in, *d_o;
  cudaMalloc(&d_in, sizeof h_in);
  cudaMalloc(&d_o, sizeof h);
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d_in);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d_o, sizeof h, cudaMemcpyDeviceToHost);
  int warp = 0;
  for (int i = 0; i < n; i++) warp += h_in[i];
  for (int i = 0; i < n; i++) {
    int x = h_in[i];
    int e0 = host_pick(x) + 2 * host_pick(x) + 7;  // pick + twice, then bump by 7
    int tri = x > 0 ? x * (x + 1) / 2 : 0;         // sum_to(x)
    int e1 = tri + 4 * x + 6;                      // sum_to(x) + table_sum(x) = sum_to(x) + (4x + 6)
    if (h[i] != e0) want++;
    if (h[32 + i] != e1) want++;
    if (h[64 + i] != warp) want++;
    int bc = (x + 1) + (int)(x * 0.5f) + x;  // bump_copy(make_pair(x)) + p.a, the copy's bump not seen by p.a
    if (h[96 + i] != bc) want++;
    if (h[128 + i] != 3 * (x + (int)(x * 0.5f))) want++;
  }
  printf("inline_device: %s, %d mismatches\n", cudaGetErrorString(err), want);
  cudaFree(d_in);
  cudaFree(d_o);
  return err != cudaSuccess || want != 0;
}
