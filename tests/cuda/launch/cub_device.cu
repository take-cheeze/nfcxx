// The device-wide CUB algorithms of the host shim (lib/cuda/host/cub/cub.cuh, implemented in lib/cuda/cub/device.cu and
// linked with -lcudart): DeviceReduce::Sum, DeviceScan::InclusiveSum, DeviceRadixSort::SortPairs on one segment and
// DeviceSegmentedSort::SortPairsDescending on three, against host references. The keys repeat (2001 values over 5000
// items), so the sorts must be stable: the values (the indices) are compared with std::stable_sort's.
#include <cuda_runtime.h>
#include <cub/cub.cuh>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <vector>
#include <algorithm>
int main() {
  const int n = 5000, rows = 3, cols = 1000;
  std::vector<float> h(n);
  srand(1);
  for (int i = 0; i < n; i++) h[i] = (float)(rand() % 2001 - 1000) / 7.0f;   // duplicates: stability matters
  float *d, *dout, *dk; int *dv, *dvo, *doff;
  cudaMalloc(&d, n * 4); cudaMalloc(&dout, n * 4); cudaMalloc(&dk, n * 4); cudaMalloc(&dv, n * 4); cudaMalloc(&dvo, n * 4);
  cudaMalloc(&doff, 4 * 4);
  cudaMemcpy(d, h.data(), n * 4, cudaMemcpyHostToDevice);
  int bad = 0;
  // sum
  size_t bytes = 0; cub::DeviceReduce::Sum(nullptr, bytes, d, dout, n); void *tmp; cudaMalloc(&tmp, bytes);
  cub::DeviceReduce::Sum(tmp, bytes, d, dout, n); float s; cudaMemcpy(&s, dout, 4, cudaMemcpyDeviceToHost);
  double ref = 0; for (float x : h) ref += x; bad += fabs(s - ref) > 1e-2 * (1 + fabs(ref));
  // inclusive scan
  bytes = 0; cub::DeviceScan::InclusiveSum(nullptr, bytes, d, dout, n); cudaFree(tmp); cudaMalloc(&tmp, bytes);
  cub::DeviceScan::InclusiveSum(tmp, bytes, d, dout, n); std::vector<float> sc(n); cudaMemcpy(sc.data(), dout, n * 4, cudaMemcpyDeviceToHost);
  double acc = 0; for (int i = 0; i < n; i++) { acc += h[i]; bad += fabs(sc[i] - acc) > 1e-2 * (1 + fabs(acc)); }
  // sorts: ascending one segment, descending segmented
  std::vector<int> idx(n); for (int i = 0; i < n; i++) idx[i] = i;
  cudaMemcpy(dv, idx.data(), n * 4, cudaMemcpyHostToDevice);
  for (int desc = 0; desc < 2; desc++) {
    int offs[4] = {0, cols, 2 * cols, 3 * cols};
    cudaMemcpy(doff, offs, sizeof offs, cudaMemcpyHostToDevice);
    const int m = desc ? rows * cols : n;
    bytes = 0;
    if (!desc) cub::DeviceRadixSort::SortPairs(nullptr, bytes, d, dk, dv, dvo, m, 0, sizeof(float) * 8);
    else cub::DeviceSegmentedSort::SortPairsDescending(nullptr, bytes, d, dk, dv, dvo, m, rows, doff, doff + 1);
    cudaFree(tmp); cudaMalloc(&tmp, bytes);
    cudaError_t e = !desc ? cub::DeviceRadixSort::SortPairs(tmp, bytes, d, dk, dv, dvo, m, 0, sizeof(float) * 8)
                          : cub::DeviceSegmentedSort::SortPairsDescending(tmp, bytes, d, dk, dv, dvo, m, rows, doff, doff + 1);
    bad += e != cudaSuccess;
    std::vector<int> got(m); std::vector<float> gk(m);
    cudaMemcpy(got.data(), dvo, m * 4, cudaMemcpyDeviceToHost); cudaMemcpy(gk.data(), dk, m * 4, cudaMemcpyDeviceToHost);
    for (int seg = 0; seg < (desc ? rows : 1); seg++) {
      const int b = desc ? seg * cols : 0, len = desc ? cols : n;
      std::vector<int> want(idx.begin() + b, idx.begin() + b + len);
      std::stable_sort(want.begin(), want.end(), [&](int x, int y) { return desc ? h[x] > h[y] : h[x] < h[y]; });
      for (int i = 0; i < len; i++) { bad += got[b + i] != want[i]; bad += gk[b + i] != h[want[i]]; }
    }
  }
  printf("cub device-wide: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
