// Vector-typed loads (float2, float4) through pointers: the struct copy uses words of the type's alignment (8 and 16
// bytes), and the values are the host's.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(float *o, const float2 *in2, const float4 *in4) {
  int i = threadIdx.x;
  float2 a = in2[i];
  float4 b = in4[i];
  o[i] = a.x + a.y + b.x + b.y + b.z + b.w;
}

int main() {
  const int n = 32;
  float2 h2[n];
  float4 h4[n];
  float h_o[n];
  for (int i = 0; i < n; i++) {
    h2[i] = make_float2(0.5f * i, 1.0f + i);
    h4[i] = make_float4(2.0f * i, 0.25f * i, -1.0f, 3.0f);
  }
  float2 *d2;
  float4 *d4;
  float *d_o;
  cudaMalloc(&d2, sizeof h2);
  cudaMalloc(&d4, sizeof h4);
  cudaMalloc(&d_o, sizeof h_o);
  cudaMemcpy(d2, h2, sizeof h2, cudaMemcpyHostToDevice);
  cudaMemcpy(d4, h4, sizeof h4, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d2, d4);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h_o, d_o, sizeof h_o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float e = h2[i].x + h2[i].y + h4[i].x + h4[i].y + h4[i].z + h4[i].w;
    if (h_o[i] != e) bad++;
  }
  printf("vec_copy: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d2);
  cudaFree(d4);
  cudaFree(d_o);
  return err != cudaSuccess || bad != 0;
}
