// Struct copies between locals: the copy moves words (the two frame slots are aligned), and the values are the host's.
#include <cuda_runtime.h>
#include <stdio.h>

struct S {
  float a[4];
  int b;
  unsigned short c;
};

struct D {
  long long p;
  double q;
};

// A copy inside an inlined function: the callee's slots have their own alignments (the caller has slots of the same names)
__device__ __forceinline__ float via(float v, int i) {
  S x;
  for (int j = 0; j < 4; j++) x.a[j] = v + j;
  x.b = i;
  x.c = (unsigned short)i;
  S y = x;
  return y.a[3] + (float)y.b;
}

__global__ void k(float *o, const float *in) {
  int i = threadIdx.x;
  S x;
  for (int j = 0; j < 4; j++) x.a[j] = in[i] + j;
  x.b = i;
  x.c = (unsigned short)i;
  S y = x;
  y.a[0] += 1.0f;
  D u;
  u.p = i;
  u.q = 0.5 * i;
  D v = u;
  o[i] = y.a[0] + x.a[0] + y.a[3] + (float)y.b + (float)y.c + (float)v.p + (float)v.q + via(in[i], i);
}

int main() {
  const int n = 32;
  float h_in[n], h_o[n];
  for (int i = 0; i < n; i++) h_in[i] = (float)(i % 7) * 0.5f;
  float *d_in, *d_o;
  cudaMalloc(&d_in, sizeof h_in);
  cudaMalloc(&d_o, sizeof h_o);
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d_in);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h_o, d_o, sizeof h_o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float x0 = h_in[i], x3 = h_in[i] + 3, y0 = h_in[i] + 1;
    float vi = h_in[i] + 3 + (float)i;
    float e = y0 + x0 + x3 + (float)i + (float)(unsigned short)i + (float)i + (float)(0.5 * i) + vi;
    if (h_o[i] != e) bad++;
  }
  printf("copy_words: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d_in);
  cudaFree(d_o);
  return err != cudaSuccess || bad != 0;
}
