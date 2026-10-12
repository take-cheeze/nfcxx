// Unqualified min and max in device code (CUDA's math overloads for the numeric types), against the host, exactly.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void kminmax(const int *a, const unsigned *u, const float *f, const double *d, const long long *l,
                        int *oi, unsigned *ou, float *of, double *od, long long *ol, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int b = a[(i + 1) % n];
  oi[2 * i] = min(a[i], b);
  oi[2 * i + 1] = max(a[i], b);
  ou[2 * i] = min(u[i], u[(i + 1) % n]);
  ou[2 * i + 1] = max(u[i], u[(i + 1) % n]);
  of[2 * i] = min(f[i], f[(i + 1) % n]);
  of[2 * i + 1] = max(f[i], f[(i + 1) % n]);
  od[2 * i] = min(d[i], d[(i + 1) % n]);
  od[2 * i + 1] = max(d[i], d[(i + 1) % n]);
  ol[2 * i] = min(l[i], l[(i + 1) % n]);
  ol[2 * i + 1] = max(l[i], l[(i + 1) % n]);
}

int main() {
  const int n = 256;
  int ha[n]; unsigned hu[n]; float hf[n]; double hd[n]; long long hl[n];
  for (int i = 0; i < n; i++) {
    ha[i] = (i * 37) % 101 - 50; hu[i] = (unsigned)((i * 53) % 97); hf[i] = (float)((i * 29) % 83) / 7.0f - 5.0f;
    hd[i] = (double)((i * 31) % 79) / 3.0 - 9.0; hl[i] = (long long)((i * 41) % 113) * 1000003LL - 40000000LL;
  }
  int *da, *doi; unsigned *du, *dou; float *df, *dof; double *dd, *dod; long long *dl, *dol;
  cudaMalloc((void **)&da, sizeof ha); cudaMalloc((void **)&doi, 2 * sizeof ha);
  cudaMalloc((void **)&du, sizeof hu); cudaMalloc((void **)&dou, 2 * sizeof hu);
  cudaMalloc((void **)&df, sizeof hf); cudaMalloc((void **)&dof, 2 * sizeof hf);
  cudaMalloc((void **)&dd, sizeof hd); cudaMalloc((void **)&dod, 2 * sizeof hd);
  cudaMalloc((void **)&dl, sizeof hl); cudaMalloc((void **)&dol, 2 * sizeof hl);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice); cudaMemcpy(du, hu, sizeof hu, cudaMemcpyHostToDevice);
  cudaMemcpy(df, hf, sizeof hf, cudaMemcpyHostToDevice); cudaMemcpy(dd, hd, sizeof hd, cudaMemcpyHostToDevice);
  cudaMemcpy(dl, hl, sizeof hl, cudaMemcpyHostToDevice);
  kminmax<<<(n + 127) / 128, 128>>>(da, du, df, dd, dl, doi, dou, dof, dod, dol, n);
  cudaError_t err = cudaDeviceSynchronize();
  int oi[2 * n]; unsigned ou[2 * n]; float of[2 * n]; double od[2 * n]; long long ol[2 * n];
  cudaMemcpy(oi, doi, sizeof oi, cudaMemcpyDeviceToHost); cudaMemcpy(ou, dou, sizeof ou, cudaMemcpyDeviceToHost);
  cudaMemcpy(of, dof, sizeof of, cudaMemcpyDeviceToHost); cudaMemcpy(od, dod, sizeof od, cudaMemcpyDeviceToHost);
  cudaMemcpy(ol, dol, sizeof ol, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    int j = (i + 1) % n;
    bad += oi[2 * i] != (ha[i] < ha[j] ? ha[i] : ha[j]) || oi[2 * i + 1] != (ha[i] > ha[j] ? ha[i] : ha[j]);
    bad += ou[2 * i] != (hu[i] < hu[j] ? hu[i] : hu[j]) || ou[2 * i + 1] != (hu[i] > hu[j] ? hu[i] : hu[j]);
    bad += of[2 * i] != (hf[i] < hf[j] ? hf[i] : hf[j]) || of[2 * i + 1] != (hf[i] > hf[j] ? hf[i] : hf[j]);
    bad += od[2 * i] != (hd[i] < hd[j] ? hd[i] : hd[j]) || od[2 * i + 1] != (hd[i] > hd[j] ? hd[i] : hd[j]);
    bad += ol[2 * i] != (hl[i] < hl[j] ? hl[i] : hl[j]) || ol[2 * i + 1] != (hl[i] > hl[j] ? hl[i] : hl[j]);
  }
  printf("minmax: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
