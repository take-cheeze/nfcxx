// A kernel template with a size_t pack deduced from a std::index_sequence argument, called with a literal count:
// the pack is 0, 1, 2 (make_index_sequence<3>), so the kernel sums 0 + 1 + 2 = 3.
#include <cuda_runtime.h>
#include <cstdio>
#include <utility>
template <typename T, size_t... I>
__global__ void kseq(T *y) {
  int a[] = {(int)I...};
  T s = 0;
  for (int v : a) s += (T)v;
  y[0] = s;
}
template <typename T, size_t... I>
static void lseq(T *y, cudaStream_t st, std::index_sequence<I...>) {
  kseq<T, I...><<<1, 1, 0, st>>>(y);
}
int main() {
  int *dy = nullptr;
  cudaMalloc(&dy, sizeof(int));
  lseq<int>(dy, 0, std::make_index_sequence<3>{});
  int hy = -1;
  cudaMemcpy(&hy, dy, sizeof(int), cudaMemcpyDeviceToHost);
  std::printf("index seq: %d (expect 3)\n", hy);
  cudaFree(dy);
  return hy == 3 ? 0 : 1;
}
