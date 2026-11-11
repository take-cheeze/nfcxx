// half <-> float conversions in device code, written the ways llama.cpp writes them: a cast, an initialization, a
// return, a generic cast template (ggml_cuda_cast), half arithmetic, and the lanes of a half2. Each converts the value,
// not the bits (the device half was an unsigned short, so (float)h gave 48128 for -1). Each result is exact.
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <stdio.h>

template <typename D, typename S> __device__ D cast_to(S x) { return (D)x; }
__device__ float ret_float(half h) { return h; }

__global__ void kern(const half *x, const float *f, float *out, half *hout) {
  int i = threadIdx.x;
  half h = x[i];
  float a = (float)h;                       // cast
  float b = h;                              // initialization
  float c = cast_to<float>(h);              // generic cast
  float d = ret_float(h);                   // return
  half s = h + h;                           // half arithmetic
  half2 p = make_half2(f[i], 2.0f * f[i]);
  out[4 * i + 0] = a + b;
  out[4 * i + 1] = c + d;
  out[4 * i + 2] = (float)s;
  out[4 * i + 3] = (float)p.x + (float)p.y; // half2 lanes
  hout[2 * i + 0] = (half)f[i];             // float -> half cast
  hout[2 * i + 1] = cast_to<half>(f[i] * 0.5f);
}

int main() {
  const int n = 8;
  half hx[n]; float hf[n];
  for (int i = 0; i < n; i++) { hf[i] = 0.25f * i - 1.0f; hx[i] = __float2half(hf[i]); }
  half *dx, *dh; float *df, *dout;
  cudaMalloc(&dx, sizeof hx); cudaMalloc(&df, sizeof hf); cudaMalloc(&dout, 4 * n * sizeof(float));
  cudaMalloc(&dh, 2 * n * sizeof(half));
  cudaMemcpy(dx, hx, sizeof hx, cudaMemcpyHostToDevice);
  cudaMemcpy(df, hf, sizeof hf, cudaMemcpyHostToDevice);
  kern<<<1, n>>>(dx, df, dout, dh);
  float out[4 * n]; half hout[2 * n];
  cudaMemcpy(out, dout, sizeof out, cudaMemcpyDeviceToHost);
  cudaMemcpy(hout, dh, sizeof hout, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    const float v = hf[i];
    bad += out[4 * i + 0] != 2 * v;
    bad += out[4 * i + 1] != 2 * v;
    bad += out[4 * i + 2] != 2 * v;
    bad += out[4 * i + 3] != 3 * v;
    bad += __half2float(hout[2 * i + 0]) != v;
    bad += __half2float(hout[2 * i + 1]) != 0.5f * v;
  }
  printf("half convert: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
