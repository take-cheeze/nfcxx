#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
template <typename T> __global__ void scale_tk(T *p, int n, T k);
__global__ void kM(float *p, int n) { int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) p[i] = p[i] + 100.0f; }
extern "C" void runA(float *d, int n);
extern "C" void runB(float *d, int n);
int main() {
  const int n = 1000; float h[n], r[n];
  for (int i = 0; i < n; i++) h[i] = (float)i;
  float *d; cudaMalloc(&d, n * sizeof(float));
  auto run = [&](void (*f)(float *, int), const char *name, float (*ref)(float)) {
    cudaMemcpy(d, h, n * sizeof(float), cudaMemcpyHostToDevice); f(d, n);
    cudaMemcpy(r, d, n * sizeof(float), cudaMemcpyDeviceToHost);
    int bad = 0; for (int i = 0; i < n; i++) if (r[i] != ref(h[i])) bad++;
    printf("%s: %d mismatches\n", name, bad); return bad; };
  int bad = 0;
  bad += run(runA, "libA (kA, kshared+1000, scale x3)", [](float x) { return (x * 2.0f + 1.0f + 1000.0f) * 3.0f; });
  bad += run(runB, "libB (kB, kshared+2000, scale x3)", [](float x) { return (x - 5.0f + 2000.0f) * 3.0f; });
  {
    cudaMemcpy(d, h, n * sizeof(float), cudaMemcpyHostToDevice);
    kM<<<(n + 127) / 128, 128>>>(d, n); cudaMemcpy(r, d, n * sizeof(float), cudaMemcpyDeviceToHost);
    int b = 0; for (int i = 0; i < n; i++) if (r[i] != h[i] + 100.0f) b++;
    printf("main kM: %d mismatches\n", b); bad += b;
  }
  printf("total mismatches: %d\n", bad); cudaFree(d); return bad != 0;
}
