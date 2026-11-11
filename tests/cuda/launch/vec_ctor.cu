// An array of class objects whose default constructor does something (a default member initializer that converts
// floats to half2, as llama.cpp's mma tiles do): the front end lowers `tile a[2];` to __cxa_vec_ctor with the
// constructor, and the constructor zeroes the object with memset first. The emitter lowers both (one direct call per
// element, byte stores). Each element's lanes must hold the initializer's values, checked exactly.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>

struct tile {
  half2 x[4] = {{1.0f, 2.0f}};
};

__global__ void kern(float *out) {
  tile a[3];
  a[1].x[2] = make_half2(5.0f, 6.0f);
  for (int t = 0; t < 3; t++)
    for (int k = 0; k < 4; k++) {
      out[(t * 4 + k) * 2 + 0] = __low2float(a[t].x[k]);
      out[(t * 4 + k) * 2 + 1] = __high2float(a[t].x[k]);
    }
}

int main() {
  float *d;
  cudaMalloc(&d, 24 * sizeof(float));
  cudaMemset(d, 0xff, 24 * sizeof(float));
  kern<<<1, 1>>>(d);
  float h[24];
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < 3; t++)
    for (int k = 0; k < 4; k++) {
      float lo = k == 0 ? 1.0f : 0.0f, hi = k == 0 ? 2.0f : 0.0f;  // the rest of the array is value-initialized
      if (t == 1 && k == 2) { lo = 5.0f; hi = 6.0f; }
      bad += h[(t * 4 + k) * 2] != lo;
      bad += h[(t * 4 + k) * 2 + 1] != hi;
    }
  printf("vec ctor: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
