// Cooperative groups' warp tiles through the device prelude (COOP_DEF in tools/cuda-rewrite): tiled_partition<N>,
// cg::reduce with cg::plus over a tile, and the tile's shfl, shfl_down, shfl_up and shfl_xor, for N = 4, 8, 16 and 32,
// on int and double, exactly against the host. A mutant (shfl_down by 2 instead of 1) must fail.
#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include <stdio.h>

namespace cg = cooperative_groups;

template <unsigned N>
__global__ void ktile(const int *in, int *sum, int *down, int *up, int *xr, int *bcast, double *dsum, double *dbcast) {
  cg::thread_block cta = cg::this_thread_block();
  cg::thread_block_tile<N> tile = cg::tiled_partition<N>(cta);
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  int v = in[i];
  sum[i] = cg::reduce(tile, v, cg::plus<int>());
  down[i] = tile.shfl_down(v, 1);
  up[i] = tile.shfl_up(v, 1);
  xr[i] = tile.shfl_xor(v, 1);
  bcast[i] = tile.shfl(v, 0);
  double d = 0.5 * v;
  dsum[i] = cg::reduce(tile, d, cg::plus<double>());
  dbcast[i] = tile.shfl(d, 0);
}

const int blocks = 4, threads = 128, n = blocks * threads;

// The host's answer for a tile of N lanes: lanes are aligned to N within each block of 128 threads.
template <unsigned N>
static int check(const int *in, const int *sum, const int *down, const int *up, const int *xr, const int *bcast,
                 const double *dsum, const double *dbcast) {
  int bad = 0;
  for (int i = 0; i < n; i++) {
    int base = i - (i % N), r = i % N;
    int s = 0;
    for (int k = base; k < base + (int)N; k++) s += in[k];
    bad += sum[i] != s;
    bad += down[i] != (r + 1 < (int)N ? in[i + 1] : in[i]);
    bad += up[i] != (r >= 1 ? in[i - 1] : in[i]);
    bad += xr[i] != in[i ^ 1];
    bad += bcast[i] != in[base];
    double ds = 0.0;
    for (int k = base; k < base + (int)N; k++) ds += 0.5 * in[k];
    bad += dsum[i] != ds;
    bad += dbcast[i] != 0.5 * in[base];
  }
  return bad;
}

int main() {
  int h_in[n];
  for (int i = 0; i < n; i++) h_in[i] = (i * 7 + 3) % 101 - 50;
  int *din, *dsum, *ddown, *dup, *dxr, *dbcast;
  double *ddsum, *ddbcast;
  cudaMalloc((void **)&din, n * sizeof(int));
  cudaMalloc((void **)&dsum, n * sizeof(int)); cudaMalloc((void **)&ddown, n * sizeof(int));
  cudaMalloc((void **)&dup, n * sizeof(int)); cudaMalloc((void **)&dxr, n * sizeof(int));
  cudaMalloc((void **)&dbcast, n * sizeof(int));
  cudaMalloc((void **)&ddsum, n * sizeof(double)); cudaMalloc((void **)&ddbcast, n * sizeof(double));
  cudaMemcpy(din, h_in, n * sizeof(int), cudaMemcpyHostToDevice);

  int sum[n], down[n], up[n], xr[n], bcast[n];
  double dsum_h[n], dbcast_h[n];
  int bad = 0;

  ktile<4><<<blocks, threads>>>(din, dsum, ddown, dup, dxr, dbcast, ddsum, ddbcast);
  cudaDeviceSynchronize();
  cudaMemcpy(sum, dsum, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(down, ddown, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(up, dup, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(xr, dxr, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(bcast, dbcast, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(dsum_h, ddsum, n * sizeof(double), cudaMemcpyDeviceToHost);
  cudaMemcpy(dbcast_h, ddbcast, n * sizeof(double), cudaMemcpyDeviceToHost);
  bad += check<4>(h_in, sum, down, up, xr, bcast, dsum_h, dbcast_h);

  ktile<8><<<blocks, threads>>>(din, dsum, ddown, dup, dxr, dbcast, ddsum, ddbcast);
  cudaDeviceSynchronize();
  cudaMemcpy(sum, dsum, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(down, ddown, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(up, dup, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(xr, dxr, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(bcast, dbcast, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(dsum_h, ddsum, n * sizeof(double), cudaMemcpyDeviceToHost);
  cudaMemcpy(dbcast_h, ddbcast, n * sizeof(double), cudaMemcpyDeviceToHost);
  bad += check<8>(h_in, sum, down, up, xr, bcast, dsum_h, dbcast_h);

  ktile<16><<<blocks, threads>>>(din, dsum, ddown, dup, dxr, dbcast, ddsum, ddbcast);
  cudaDeviceSynchronize();
  cudaMemcpy(sum, dsum, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(down, ddown, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(up, dup, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(xr, dxr, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(bcast, dbcast, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(dsum_h, ddsum, n * sizeof(double), cudaMemcpyDeviceToHost);
  cudaMemcpy(dbcast_h, ddbcast, n * sizeof(double), cudaMemcpyDeviceToHost);
  bad += check<16>(h_in, sum, down, up, xr, bcast, dsum_h, dbcast_h);

  ktile<32><<<blocks, threads>>>(din, dsum, ddown, dup, dxr, dbcast, ddsum, ddbcast);
  cudaDeviceSynchronize();
  cudaMemcpy(sum, dsum, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(down, ddown, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(up, dup, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(xr, dxr, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(bcast, dbcast, n * sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(dsum_h, ddsum, n * sizeof(double), cudaMemcpyDeviceToHost);
  cudaMemcpy(dbcast_h, ddbcast, n * sizeof(double), cudaMemcpyDeviceToHost);
  bad += check<32>(h_in, sum, down, up, xr, bcast, dsum_h, dbcast_h);

  if (bad) printf("cg tile: %d mismatches\n", bad);
  else printf("cg tile: no error, 0 mismatches\n");
  return bad != 0;
}
