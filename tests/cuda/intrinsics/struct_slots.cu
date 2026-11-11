// A struct local whose constructor and member function take its address: the device compile keeps its field in a
// register (pathb-ptx-emit --struct-slots, the default) and the result is the host's. The field is a 16-bit integer,
// so its truncation and the pointer spills in the constructor and the member function are on the path too.
#include <cuda_runtime.h>
#include <stdio.h>

struct H {
  unsigned short x;
  __device__ H(float f) { x = (unsigned short)(f * 2.0f); }
  __device__ float get() const { return x * 0.5f; }
};

struct Pair {
  int a;
  float b;
  __device__ Pair(int v) : a(v), b(v * 0.25f) {}
  __device__ float sum() const { return a + b; }
};

__global__ void k(float *o, const float *in) {
  int i = threadIdx.x;
  H h(in[i]);
  o[i] = h.get() + 1.0f;
  Pair p((int)in[i]);
  o[32 + i] = p.sum();
}

int main() {
  const int n = 32;
  float h_in[n], h_o[64];
  for (int i = 0; i < n; i++) h_in[i] = (float)(i * 7 % 50) - 20.0f;
  float *d_in, *d_o;
  cudaMalloc(&d_in, sizeof h_in);
  cudaMalloc(&d_o, sizeof h_o);
  cudaMemcpy(d_in, h_in, sizeof h_in, cudaMemcpyHostToDevice);
  k<<<1, n>>>(d_o, d_in);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h_o, d_o, sizeof h_o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float t = h_in[i] * 2.0f;  // the device converts a negative value to 0 (cvt.rzi saturates)
    unsigned short x = t > 0 ? (unsigned short)(unsigned)t : 0;
    float e0 = x * 0.5f + 1.0f;
    int v = (int)h_in[i];
    float e1 = v + v * 0.25f;
    if (h_o[i] != e0) bad++;
    if (h_o[32 + i] != e1) bad++;
  }
  printf("struct_slots: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(d_in);
  cudaFree(d_o);
  return err != cudaSuccess || bad != 0;
}
