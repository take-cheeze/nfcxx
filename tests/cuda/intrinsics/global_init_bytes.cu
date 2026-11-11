// Device globals with partial initializers (the front end's IR is integer and float scalars at byte offsets plus a
// zero tail): a 16-bit array, a 32-bit array and a float array with exact values, and an array of 4-byte structs, each
// read at a run-time index in a kernel. Prints "global init bytes: no error, N mismatches".
#include <cstdint>
#include <cstdio>
#include <cuda_runtime.h>

struct Pair { uint16_t a, b; };
static const uint16_t g_u16[4] = {1, 300};
static const int32_t g_s32[3] = {-7, 9};
static const float g_f32[3] = {0.5f, -2.0f};
static const Pair g_pair[2] = {{7, 65535}};

__device__ __forceinline__ uint32_t pick_u16(int i) { return g_u16[i & 3]; }
__device__ __forceinline__ int32_t pick_s32(int i) { return g_s32[i % 3]; }
__device__ __forceinline__ float pick_f32(int i) { return g_f32[i % 3]; }
__device__ __forceinline__ uint32_t pick_pa(int i) { return g_pair[i & 1].a; }
__device__ __forceinline__ uint32_t pick_pb(int i) { return g_pair[i & 1].b; }

__global__ void kern(uint32_t *u16, int32_t *s32, float *f32, uint32_t *pa, uint32_t *pb) {
    int i = threadIdx.x;
    u16[i] = pick_u16(i);
    s32[i] = pick_s32(i);
    f32[i] = pick_f32(i);
    pa[i] = pick_pa(i);
    pb[i] = pick_pb(i);
}

int main() {
    const int n = 8;
    uint32_t *du16, *dpa, *dpb; int32_t *ds32; float *df32;
    cudaMalloc(&du16, n * 4); cudaMalloc(&ds32, n * 4); cudaMalloc(&df32, n * 4); cudaMalloc(&dpa, n * 4); cudaMalloc(&dpb, n * 4);
    kern<<<1, n>>>(du16, ds32, df32, dpa, dpb);
    uint32_t hu16[n], hpa[n], hpb[n]; int32_t hs32[n]; float hf32[n];
    cudaMemcpy(hu16, du16, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hs32, ds32, n * 4, cudaMemcpyDeviceToHost);
    cudaMemcpy(hf32, df32, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hpa, dpa, n * 4, cudaMemcpyDeviceToHost);
    cudaMemcpy(hpb, dpb, n * 4, cudaMemcpyDeviceToHost);
    const uint32_t exp_u16[4] = {1, 300, 0, 0};
    const int32_t exp_s32[3] = {-7, 9, 0};
    const float exp_f32[3] = {0.5f, -2.0f, 0.0f};
    const uint32_t exp_pa[2] = {7, 0};
    const uint32_t exp_pb[2] = {65535, 0};
    int bad = 0;
    for (int i = 0; i < n; i++) {
        bad += hu16[i] != exp_u16[i & 3];
        bad += hs32[i] != exp_s32[i % 3];
        bad += hf32[i] != exp_f32[i % 3];
        bad += hpa[i] != exp_pa[i & 1];
        bad += hpb[i] != exp_pb[i & 1];
    }
    printf("global init bytes: %s, %d mismatches\n", bad == 0 ? "no error" : "error", bad);
    return bad != 0;
}
