// The zero bytes an aggregate initializer leaves (mmvq.cu's `float tmp[ncols_dst][rows_per_cuda_block] = {{0.0f}}`)
// are stored in the widest stores the object's alignment allows. They were chosen from the offset alone, as if the
// object were 8-byte aligned: the last two floats of a 4-byte aligned float[2][2] were one 8-byte store, and the kernel
// faulted with "misaligned address" when the array sat at 4 mod 8 in the frame.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void kern(const float *in, float *out) {
  const int i = threadIdx.x;
  float a = in[i];
  float tmp[2][2] = {{0.0f}};  // a constant initializer: tmp[0][0] is stored, the other 12 bytes are zero stores
  float b = 2.0f * a;
  float tmp2[3][2] = {{0.0f}};
  tmp[0][0] = a;
  tmp2[0][0] = b;
  tmp2[0][1] = a;
  out[i] = tmp[0][0] + tmp[0][1] + tmp[1][0] + tmp[1][1] + tmp2[0][0] + tmp2[0][1] + tmp2[1][0] + tmp2[2][1];
}

int main() {
  const int n = 8;
  float h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = 1.0f + i;
  float *din, *dout;
  cudaMalloc(&din, sizeof h); cudaMalloc(&dout, sizeof o);
  cudaMemcpy(din, h, sizeof h, cudaMemcpyHostToDevice);
  kern<<<1, n>>>(din, dout);
  cudaError_t e = cudaDeviceSynchronize();
  cudaMemcpy(o, dout, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != 4.0f * h[i];
  printf("zero tail: %s, %d mismatches\n", cudaGetErrorString(e), bad);
  return bad != 0;
}
