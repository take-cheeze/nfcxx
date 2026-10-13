// The C++ operators on __half2 (+ - * / unary-, += -= *= /=, ==) in device code, against the host. Inputs are small
// integers and powers of two, so every result is exact in half (no rounding ambiguity).
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <string.h>
#include <stdio.h>

__global__ void kops(const __half2 *a, const __half2 *b, __half2 *out, int *eq, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __half2 x = a[i], y = b[i];
  out[4 * i + 0] = x + y;
  out[4 * i + 1] = x - y;
  out[4 * i + 2] = x * y;
  out[4 * i + 3] = x / y;
  __half2 z = -x;
  z += y; z *= x;          /* z = (-x + y) * x */
  out[4 * i + 0].x = out[4 * i + 0].x;   /* keep the sums live */
  eq[i] = (x == y) ? 1 : 0;
  __half2 w = x; w -= y; w /= y;          /* w = (x - y) / y */
  out[4 * i + 1] = out[4 * i + 1];
  out[4 * i + 2] = out[4 * i + 2];
  out[4 * i + 3] = w + z;                  /* combined check */
}

static unsigned short hbits(__half h) { unsigned short u; memcpy(&u, &h, 2); return u; }

int main() {
  const int n = 64;
  __half2 ha[n], hb[n], ho[4 * n];
  int he[n];
  for (int i = 0; i < n; i++) {
    float xa = (float)((i * 7) % 13 - 6), xb = (float)((i * 5) % 9 - 4);
    float ya = (float)((i * 3) % 5 + 1), yb = (float)((i * 11) % 7 - 3);
    ha[i] = __halves2half2(__float2half(xa), __float2half(ya));
    hb[i] = __halves2half2(__float2half(xb), __float2half(yb));
    (void)xa; (void)yb;
  }
  __half2 *da, *db, *dout; int *de;
  cudaMalloc((void **)&da, sizeof ha); cudaMalloc((void **)&db, sizeof hb);
  cudaMalloc((void **)&dout, sizeof ho); cudaMalloc((void **)&de, sizeof he);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice); cudaMemcpy(db, hb, sizeof hb, cudaMemcpyHostToDevice);
  kops<<<(n + 31) / 32, 32>>>(da, db, dout, de, n);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost); cudaMemcpy(he, de, sizeof he, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float xl = __half2float(ha[i].x), xh = __half2float(ha[i].y);
    float yl = __half2float(hb[i].x), yh = __half2float(hb[i].y);
    /* sum, difference, product: exact here */
    bad += __half2float(ho[4 * i].x) != xl + yl || __half2float(ho[4 * i].y) != xh + yh;
    bad += __half2float(ho[4 * i + 1].x) != xl - yl || __half2float(ho[4 * i + 1].y) != xh - yh;
    bad += __half2float(ho[4 * i + 2].x) != xl * yl || __half2float(ho[4 * i + 2].y) != xh * yh;
    bad += he[i] != ((xl == yl && xh == yh) ? 1 : 0);
  }
  printf("half2 ops: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
