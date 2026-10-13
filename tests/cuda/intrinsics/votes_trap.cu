// The warp votes (__ballot_sync, __any_sync, __all_sync) and __trap on a path that is not taken, from device code
// through the driver. Each lane's predicate is lane % 3 == 0. Checked exactly against the host.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void kvotes(unsigned *ballot, int *any, int *all, int n) {
  int t = threadIdx.x;
  int p = (t % 3) == 0;
  unsigned b = __ballot_sync(0xffffffffu, p);
  int a = __any_sync(0xffffffffu, p);
  int l = __all_sync(0xffffffffu, p);
  if (t >= n) __trap();   /* never taken: the block has n threads */
  ballot[t] = b;
  any[t] = a;
  all[t] = l;
}

int main() {
  const int n = 64;
  unsigned hb[n]; int ha[n], hl[n];
  unsigned *db; int *da, *dl;
  cudaMalloc((void **)&db, sizeof hb); cudaMalloc((void **)&da, sizeof ha); cudaMalloc((void **)&dl, sizeof hl);
  kvotes<<<1, n>>>(db, da, dl, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hb, db, sizeof hb, cudaMemcpyDeviceToHost);
  cudaMemcpy(ha, da, sizeof ha, cudaMemcpyDeviceToHost);
  cudaMemcpy(hl, dl, sizeof hl, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < n; t++) {
    int lane0 = (t / 32) * 32;
    unsigned want = 0;
    for (int l = 0; l < 32; l++) if (((lane0 + l) % 3) == 0) want |= 1u << l;
    int wany = want != 0, wall = want == 0xffffffffu;
    bad += hb[t] != want || ha[t] != wany || hl[t] != wall;
  }
  printf("votes: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
