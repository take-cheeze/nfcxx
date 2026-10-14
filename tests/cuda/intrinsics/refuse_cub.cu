// cub:: in device code is refused by name: CUB's headers are not in the device unit.
#include <cub/cub.cuh>
__global__ void k(float *o) {
  using BS = cub::BlockScan<float, 128>;
  __shared__ typename BS::TempStorage ts;
  float v = o[threadIdx.x];
  BS(ts).InclusiveSum(v, v);
  o[threadIdx.x] = v;
}
int main() { return 0; }
