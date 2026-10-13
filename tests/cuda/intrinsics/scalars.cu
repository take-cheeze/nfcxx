// Scalar helpers of ggml-cuda, on the GPU against the host, exactly: __float_as_uint (the bits), __float2int_rn
// (round half to even, saturating, NaN to 0) and __frcp_rn (correctly rounded 1/x).
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

__global__ void kscalars(const float *x, unsigned *u, int *i, float *r, int n) {
  int t = blockIdx.x * blockDim.x + threadIdx.x;
  if (t >= n) return;
  u[t] = __float_as_uint(x[t]);
  i[t] = __float2int_rn(x[t]);
  r[t] = __frcp_rn(x[t]);
}

static int ref_int(float f) {
  if (f != f) return 0;
  if (f >= 2147483647.0f) return 2147483647;
  if (f <= -2147483648.0f) return -2147483647 - 1;
  return (int)nearbyintf(f);
}

int main() {
  const int n = 4096;
  float hx[n];
  for (int t = 0; t < n; t++) {
    switch (t % 8) {
      case 0: hx[t] = (float)(t % 97) * 0.5f - 24.0f; break;    /* exact halves: ties to even */
      case 1: hx[t] = (float)(t % 53) * 0.25f + 0.1f; break;
      case 2: hx[t] = -(float)(t % 1000) * 1e5f; break;          /* large magnitudes, saturation */
      case 3: hx[t] = (t % 2) ? 3.0e9f : -3.0e9f; break;
      case 4: hx[t] = (float)(t % 17) - 8.5f; break;
      case 5: hx[t] = 0.0f; break;
      case 6: hx[t] = (t & 1) ? -0.0f : 1.0e-30f; break;
      default: hx[t] = (float)(t % 251) / 3.0f - 40.0f; break;
    }
  }
  hx[10] = __builtin_nanf("");
  float *dx, *dr; unsigned *du; int *di;
  cudaMalloc((void **)&dx, sizeof hx); cudaMalloc((void **)&dr, sizeof hx);
  cudaMalloc((void **)&du, sizeof(unsigned) * n); cudaMalloc((void **)&di, sizeof(int) * n);
  cudaMemcpy(dx, hx, sizeof hx, cudaMemcpyHostToDevice);
  kscalars<<<(n + 127) / 128, 128>>>(dx, du, di, dr, n);
  cudaError_t err = cudaDeviceSynchronize();
  static unsigned hu[n]; static int hi[n]; static float hr[n];
  cudaMemcpy(hu, du, sizeof hu, cudaMemcpyDeviceToHost);
  cudaMemcpy(hi, di, sizeof hi, cudaMemcpyDeviceToHost);
  cudaMemcpy(hr, dr, sizeof hr, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < n; t++) {
    unsigned wu; memcpy(&wu, &hx[t], sizeof wu);
    bad += hu[t] != wu;
    bad += hi[t] != ref_int(hx[t]);
    float wr = 1.0f / hx[t];
    unsigned a, b; memcpy(&a, &hr[t], 4); memcpy(&b, &wr, 4);
    bad += a != b && !(hr[t] != hr[t] && wr != wr);
  }
  printf("scalars: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
