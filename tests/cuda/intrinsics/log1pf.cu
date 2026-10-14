// log1pf through the device prelude (log(u) * x / (u - 1), u = 1 + x), against log1p in double rounded to float.
// The error is in ulps of the reference. The bound is the measured maximum for this grid (set below); edge cases are exact.
#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

__global__ void klog1p(const float *x, float *y, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) y[i] = log1pf(x[i]);
}

// the distance in representable floats between a and b (monotone bit ordering); NaN handled by the caller
static long long ulps(float a, float b) {
  int ia, ib;
  memcpy(&ia, &a, 4); memcpy(&ib, &b, 4);
  if (ia < 0) ia = (int)(0x80000000u - (unsigned)ia);
  if (ib < 0) ib = (int)(0x80000000u - (unsigned)ib);
  long long d = (long long)ia - ib;
  return d < 0 ? -d : d;
}

int main() {
  const int n = 1 << 20;
  const int edges = 12;
  static float hx[n + edges], hy[n + edges];
  // a dense grid over (-1, 100], plus small magnitudes on both sides of zero
  for (int i = 0; i < n; i++) {
    double t = (double)i / (n - 1);
    hx[i] = (float)(-0.999 + t * 99.999);
  }
  float edge[edges] = {0.0f, -0.0f, -1.0f, 1.0f / 0.0f, -1.0f / 0.0f, 0.0f / 0.0f, -2.0f, 1e-30f, -1e-30f, 1e-8f, -1e-8f, 3e38f};
  for (int i = 0; i < edges; i++) hx[n + i] = edge[i];
  float *dx, *dy;
  cudaMalloc((void **)&dx, sizeof hx); cudaMalloc((void **)&dy, sizeof hy);
  cudaMemcpy(dx, hx, sizeof hx, cudaMemcpyHostToDevice);
  int total = n + edges;
  klog1p<<<(total + 255) / 256, 256>>>(dx, dy, total);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hy, dy, sizeof hy, cudaMemcpyDeviceToHost);

  long long worst = 0;
  int bad_edge = 0, over = 0;
  const long long bound = 1;  // ulps: the measured maximum on this grid is 0 (CUDA's own log1pf is within 2 ulps)
  for (int i = 0; i < total; i++) {
    float x = hx[i], y = hy[i];
    double r = log1p((double)x);
    if (i >= n) {  // edge cases: the exact answers
      float e = (float)r;
      if (x != x) bad_edge += !(y != y);
      else if (e != e) bad_edge += !(y != y);
      else bad_edge += y != e && !(y == 0.0f && e == 0.0f);
      continue;
    }
    if (r != r) { over += !(y != y); continue; }
    float e = (float)r;
    if (e != e || y != y) { over += 1; continue; }
    long long u = ulps(y, e);
    if (u > worst) worst = u;
    over += u > bound;
  }
  printf("log1pf: %s, max %lld ulps over %d points, %d over the bound, %d edge mismatches\n",
         cudaGetErrorString(err), worst, n, over, bad_edge);
  return (over != 0 || bad_edge != 0) ? 1 : 0;
}
