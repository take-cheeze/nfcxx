// A dispatch function returns a function pointer whose template argument comes from a typedef and a template alias
// (convert.cu's ggml_get_to_fp16_cuda): `return copy_block;` takes dst_t from the returned type, and the launch in
// copy_block depends on it.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename dst_t>
__global__ void copy_k(const float *x, dst_t *y) {
  int k = threadIdx.x;
  y[k] = (dst_t)(x[k] * 2.0f);
}

template <typename dst_t>
static void copy_block(const void *vx, dst_t *y, int n, cudaStream_t stream) {
  copy_k<dst_t><<<1, n, 0, stream>>>((const float *)vx, y);
}

template <typename T> using to_t = void (*)(const void *x, T *y, int n, cudaStream_t stream);
typedef to_t<float> to_f32_t;
typedef to_t<double> to_f64_t;

to_f32_t get_to_f32() { return copy_block; }
to_f64_t get_to_f64() { return copy_block; }

int main() {
  const int n = 4;
  float hx[n] = {1, 2, 3, 4};
  float *x, *yf;
  double *yd;
  cudaMalloc((void **)&x, sizeof(hx));
  cudaMalloc((void **)&yf, n * sizeof(float));
  cudaMalloc((void **)&yd, n * sizeof(double));
  cudaMemcpy(x, hx, sizeof(hx), cudaMemcpyHostToDevice);
  get_to_f32()(x, yf, n, 0);
  get_to_f64()(x, yd, n, 0);
  cudaDeviceSynchronize();
  float rf[n];
  double rd[n];
  cudaMemcpy(rf, yf, sizeof(rf), cudaMemcpyDeviceToHost);
  cudaMemcpy(rd, yd, sizeof(rd), cudaMemcpyDeviceToHost);
  int ok = rf[0] == 2 && rf[3] == 8 && rd[1] == 4 && rd[2] == 6;
  printf("fnptr return: %s (%g %g %g)\n", ok ? "exact" : "mismatch", rf[3], rd[1], rd[2]);
  cudaFree(x); cudaFree(yf); cudaFree(yd);
  return ok ? 0 : 1;
}
