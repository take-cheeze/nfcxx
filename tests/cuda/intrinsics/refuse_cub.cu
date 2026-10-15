// A device-wide CUB call in device code is refused by name: it launches its own kernels and needs temporary storage.
#include <cub/cub.cuh>
__global__ void k(float *o) {
  int ts = 0;
  float v = o[threadIdx.x];
  cub::DeviceScan::InclusiveSum(&ts, v);
  o[threadIdx.x] = v;
}
int main() { return 0; }
