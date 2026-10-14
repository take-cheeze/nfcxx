// __shared__ __align__(16) objects (conv2d.cu's pattern): a 16-byte int4 store into a half2 array, read back as 32-bit
// words and checked exactly against the host. The half2 array's natural alignment is 4; the int4 store needs 16, so the
// alignment has to reach the emitter's .shared declaration (the rewriter's refuse_shared_align is removed). The char array
// before h makes its natural offset odd: a dropped alignment places h at an odd address, and its 4-byte stores fault.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>
#include <string.h>

__global__ void kalign(int *out) {
  __shared__ __align__(16) int pad[3];
  __shared__ char one[1];
  __shared__ __align__(16) half2 h[64];
  int t = threadIdx.x;
  if (t == 0) { pad[0] = 7; one[0] = 1; }
  __syncthreads();
  int4 v = make_int4(4 * t, 4 * t + 1, 4 * t + 2, 4 * t + 3);
  reinterpret_cast<int4 *>(h)[t] = v;
  __syncthreads();
  for (int k = 0; k < 4; k++) out[4 * t + k] = reinterpret_cast<int *>(h)[4 * t + k];
  if (t == 0) out[64] = pad[0];
}

int main() {
  int *dout;
  cudaMalloc((void **)&dout, 65 * sizeof(int));
  kalign<<<1, 16>>>(dout);
  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("shared align: kernel error %s\n", cudaGetErrorString(err));
    return 1;
  }
  int out[65];
  cudaMemcpy(out, dout, sizeof out, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 64; i++) bad += out[i] != i;
  bad += out[64] != 7;
  printf("shared align: no error, %d mismatches\n", bad);
  return bad != 0;
}
