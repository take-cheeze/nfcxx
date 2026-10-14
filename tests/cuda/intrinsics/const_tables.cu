// Initialized const arrays of scalars in device code (a lookup table, as norm.cu's kmask_iq2xs): each element type
// is read at a run-time index in a kernel and checked against the host values. Prints "const tables: no error, N mismatches".
#include <cstdint>
#include <cstdio>
#include <cuda_runtime.h>

static const uint8_t t_u8[8] = {1, 2, 4, 8, 16, 32, 64, 128};
static const int8_t t_s8[4] = {-1, 2, -128, 127};
static const uint16_t t_u16[4] = {1, 300, 40000, 65535};
static const int16_t t_s16[4] = {-1, 300, -30000, 32767};
static const uint32_t t_u32[4] = {1u, 70000u, 0x80000000u, 0xffffffffu};
static const int32_t t_s32[4] = {-1, 70000, -2000000000, 2147483647};
static const float t_f32[4] = {0.5f, -1.25f, 3.0e5f, 1.0f / 3.0f};
static const double t_f64[4] = {0.25, -2.5, 1.0e100, 1.0 / 7.0};
static const bool t_b[4] = {true, false, false, true};

__device__ __forceinline__ uint32_t pick_u8(int i) { return t_u8[i & 7]; }
__device__ __forceinline__ int32_t pick_s8(int i) { return t_s8[i & 3]; }
__device__ __forceinline__ uint32_t pick_u16(int i) { return t_u16[i & 3]; }
__device__ __forceinline__ int32_t pick_s16(int i) { return t_s16[i & 3]; }
__device__ __forceinline__ uint32_t pick_u32(int i) { return t_u32[i & 3]; }
__device__ __forceinline__ int32_t pick_s32(int i) { return t_s32[i & 3]; }
__device__ __forceinline__ float pick_f32(int i) { return t_f32[i & 3]; }
__device__ __forceinline__ double pick_f64(int i) { return t_f64[i & 3]; }
__device__ __forceinline__ int pick_b(int i) { return t_b[i & 3] ? 1 : 0; }

__global__ void kern(uint32_t *u8, int32_t *s8, uint32_t *u16, int32_t *s16, uint32_t *u32, int32_t *s32,
                     float *f32, double *f64, int *b) {
    int i = threadIdx.x;
    u8[i] = pick_u8(i);
    s8[i] = pick_s8(i);
    u16[i] = pick_u16(i);
    s16[i] = pick_s16(i);
    u32[i] = pick_u32(i);
    s32[i] = pick_s32(i);
    f32[i] = pick_f32(i);
    f64[i] = pick_f64(i);
    b[i] = pick_b(i);
}

int main() {
    const int n = 8;
    uint32_t *du8, *du16, *du32; int32_t *ds8, *ds16, *ds32; float *df32; double *df64; int *db;
    cudaMalloc(&du8, n * 4); cudaMalloc(&ds8, n * 4); cudaMalloc(&du16, n * 4); cudaMalloc(&ds16, n * 4);
    cudaMalloc(&du32, n * 4); cudaMalloc(&ds32, n * 4); cudaMalloc(&df32, n * 4); cudaMalloc(&df64, n * 8);
    cudaMalloc(&db, n * 4);
    kern<<<1, n>>>(du8, ds8, du16, ds16, du32, ds32, df32, df64, db);
    uint32_t hu8[n], hu16[n], hu32[n]; int32_t hs8[n], hs16[n], hs32[n]; float hf32[n]; double hf64[n]; int hb[n];
    cudaMemcpy(hu8, du8, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hs8, ds8, n * 4, cudaMemcpyDeviceToHost);
    cudaMemcpy(hu16, du16, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hs16, ds16, n * 4, cudaMemcpyDeviceToHost);
    cudaMemcpy(hu32, du32, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hs32, ds32, n * 4, cudaMemcpyDeviceToHost);
    cudaMemcpy(hf32, df32, n * 4, cudaMemcpyDeviceToHost); cudaMemcpy(hf64, df64, n * 8, cudaMemcpyDeviceToHost);
    cudaMemcpy(hb, db, n * 4, cudaMemcpyDeviceToHost);
    int bad = 0;
    for (int i = 0; i < n; i++) {
        bad += hu8[i] != t_u8[i & 7];
        bad += hs8[i] != t_s8[i & 3];
        bad += hu16[i] != t_u16[i & 3];
        bad += hs16[i] != t_s16[i & 3];
        bad += hu32[i] != t_u32[i & 3];
        bad += hs32[i] != t_s32[i & 3];
        bad += hf32[i] != t_f32[i & 3];
        bad += hf64[i] != t_f64[i & 3];
        bad += hb[i] != (t_b[i & 3] ? 1 : 0);
    }
    printf("const tables: no error, %d mismatches\n", bad);
    return bad != 0;
}
