#line 1 "rewrite/syncwarp.cu"
static void warp_sum(float *x) {
  __syncwarp();
  x[threadIdx.x] += 1.0f;
  __syncwarp(0xffffffffu);
}
