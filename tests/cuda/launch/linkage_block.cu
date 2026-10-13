// A kernel and a device function in a linkage block that also holds host-only declarations: the device unit carries the
// device function and its constant (inside the block's extern "C"), not the host struct with FILE *.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
extern "C" {
struct Host { FILE *f; int64_t n; };
void host_only(FILE *f);

__device__ int scaled(int x) { return x * 3; }
}
__global__ void k(int *o) { o[threadIdx.x] = scaled((int) threadIdx.x) + 1; }
int main() {
  int *d = nullptr, h[8] = {};
  cudaMalloc(&d, sizeof h);
  k<<<1, 8>>>(d);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 8; i++) bad += h[i] != 3 * i + 1;
  printf("linkage block: no error, %d mismatches\n", bad);
  cudaFree(d);
  return bad != 0;
}
