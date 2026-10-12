#line 1 "rewrite/syncwarp.cu"
__global__ void warp_sum(float *x) {
  __syncwarp();
  x[threadIdx.x] += 1.0f;
  __syncwarp(0xffffffffu);
}
