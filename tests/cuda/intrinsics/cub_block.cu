// CUB's block-level members used by ggml-cuda (the device prelude's CUB_DEF in tools/cuda-rewrite/cuda_rewrite.cpp):
// cub::BlockScan::InclusiveSum with the block aggregate for block sizes 32, 64, 128 and 256, and cub::BlockLoad and
// cub::BlockStore with the warp-transpose algorithm for 1, 4 and 8 items per thread, exactly against the host.
// A mutant (the warp offset dropped from the lowered scan) must fail.
#include <cub/cub.cuh>
#include <cuda_runtime.h>
#include <stdio.h>

template <int BLOCK>
__global__ void scan_kernel(const int *in, int *out, int *agg) {
    typedef cub::BlockScan<int, BLOCK> BlockScan;
    __shared__ typename BlockScan::TempStorage temp;
    int i = blockIdx.x * BLOCK + threadIdx.x;
    int total = 0;
    int v = 0;
    BlockScan(temp).InclusiveSum(in[i], v, total);
    out[i] = v;
    agg[i] = total;
}

template <int N>
__global__ void load_store_kernel(const int *in, int *out) {
    typedef cub::BlockLoad<int, 128, N, cub::BLOCK_LOAD_WARP_TRANSPOSE> BlockLoad;
    typedef cub::BlockStore<int, 128, N, cub::BLOCK_STORE_WARP_TRANSPOSE> BlockStore;
    __shared__ union {
        typename BlockLoad::TempStorage load;
        typename BlockStore::TempStorage store;
    } temp;
    int items[N];
    int base = blockIdx.x * 128 * N;
    BlockLoad(temp.load).Load(in + base, items);
    __syncthreads();
    for (int n = 0; n < N; n++) items[n] = 2 * items[n] + 1;
    BlockStore(temp.store).Store(out + base, items);
}

template <int BLOCK>
static int check_scan(const int *in, const int *out, const int *agg, int blocks) {
    int bad = 0;
    for (int b = 0; b < blocks; b++) {
        int run = 0;
        for (int t = 0; t < BLOCK; t++) {
            run += in[b * BLOCK + t];
            bad += out[b * BLOCK + t] != run;
        }
        // The block aggregate is the block's total, the same for every thread.
        for (int t = 0; t < BLOCK; t++) bad += agg[b * BLOCK + t] != run;
    }
    return bad;
}

template <int BLOCK>
static int run_scan(int blocks) {
    int n = blocks * BLOCK;
    int *in = new int[n], *out = new int[n], *agg = new int[n];
    for (int i = 0; i < n; i++) in[i] = (i * 7) % 13 - 6;
    int *din, *dout, *dagg;
    cudaMalloc(&din, n * sizeof(int));
    cudaMalloc(&dout, n * sizeof(int));
    cudaMalloc(&dagg, n * sizeof(int));
    cudaMemcpy(din, in, n * sizeof(int), cudaMemcpyHostToDevice);
    scan_kernel<BLOCK><<<blocks, BLOCK>>>(din, dout, dagg);
    cudaMemcpy(out, dout, n * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(agg, dagg, n * sizeof(int), cudaMemcpyDeviceToHost);
    int bad = check_scan<BLOCK>(in, out, agg, blocks);
    cudaFree(din);
    cudaFree(dout);
    cudaFree(dagg);
    delete[] in;
    delete[] out;
    delete[] agg;
    return bad;
}

template <int N>
static int run_load_store(int blocks) {
    int n = blocks * 128 * N;
    int *in = new int[n], *out = new int[n];
    for (int i = 0; i < n; i++) in[i] = (i * 5) % 17 - 8;
    int *din, *dout;
    cudaMalloc(&din, n * sizeof(int));
    cudaMalloc(&dout, n * sizeof(int));
    cudaMemcpy(din, in, n * sizeof(int), cudaMemcpyHostToDevice);
    load_store_kernel<N><<<blocks, 128>>>(din, dout);
    cudaMemcpy(out, dout, n * sizeof(int), cudaMemcpyDeviceToHost);
    int bad = 0;
    for (int i = 0; i < n; i++) bad += out[i] != 2 * in[i] + 1;
    cudaFree(din);
    cudaFree(dout);
    delete[] in;
    delete[] out;
    return bad;
}

int main() {
    int bad = 0;
    bad += run_scan<32>(8);
    bad += run_scan<64>(4);
    bad += run_scan<128>(4);
    bad += run_scan<256>(2);
    bad += run_load_store<1>(4);
    bad += run_load_store<4>(3);
    bad += run_load_store<8>(2);
    if (cudaDeviceSynchronize() != cudaSuccess) bad++;
    if (bad) {
        printf("cub block: %d mismatches\n", bad);
        return 1;
    }
    printf("cub block: no error, 0 mismatches\n");
    return 0;
}
