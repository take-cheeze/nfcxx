// Host shim for CUB's umbrella header, found before CUDA's own cub/cub.cuh on the host copy's include path (the
// driver adds lib/cuda/host first). CUB 13's headers do not parse in the host front end (CCCL's get_sreg_laneid and
// inline asm constraints), and the host copy never runs device code, so the classes the device unit lowers
// (CUB_DEF in tools/cuda-rewrite/cuda_rewrite.cpp) are declared here with host bodies that return their input.
// The device-wide algorithms ggml-cuda calls are overloads for its types, forwarding to lib/cuda/cub/device.cu (built
// by scripts/cuda-cub and linked with -lcudart). The others are declared only, so a call of one fails at link time.
#pragma once
#include <stddef.h>

#include <cuda_runtime.h>
#include <cuda_bf16.h>

namespace cub {
enum BlockLoadAlgorithm { BLOCK_LOAD_DIRECT, BLOCK_LOAD_WARP_TRANSPOSE };
enum BlockStoreAlgorithm { BLOCK_STORE_DIRECT, BLOCK_STORE_WARP_TRANSPOSE };

template <typename T, int BLOCK_THREADS, int ITEMS_PER_THREAD, BlockLoadAlgorithm ALGORITHM = BLOCK_LOAD_DIRECT>
class BlockLoad {
public:
  struct TempStorage { int unused; };
  BlockLoad(TempStorage &) {}
  void Load(const T *, T (&)[ITEMS_PER_THREAD]) const {}
};

template <typename T, int BLOCK_THREADS, int ITEMS_PER_THREAD, BlockStoreAlgorithm ALGORITHM = BLOCK_STORE_DIRECT>
class BlockStore {
public:
  struct TempStorage { int unused; };
  BlockStore(TempStorage &) {}
  void Store(T *, const T (&)[ITEMS_PER_THREAD]) const {}
};

template <typename T, int BLOCK_THREADS>
class BlockScan {
public:
  struct TempStorage { T unused[BLOCK_THREADS / 32]; };
  BlockScan(TempStorage &) {}
  void InclusiveSum(T input, T &output) const { output = input; }
  void InclusiveSum(T input, T &output, T &block_aggregate) const {
    output = input;
    block_aggregate = input;
  }
};

// lib/cuda/cub/device.cu: nseg = 0 sorts one segment of n items; otherwise segment s is [begin[s], end[s]).
extern "C" cudaError_t __nfcxx_cub_reduce_sum_f32(void *, size_t *, const float *, float *, long long, cudaStream_t);
extern "C" cudaError_t __nfcxx_cub_scan_sum_f32(void *, size_t *, const float *, float *, long long, cudaStream_t);
extern "C" cudaError_t __nfcxx_cub_scan_sum_bf16(void *, size_t *, const unsigned short *, unsigned short *, long long,
                                                 cudaStream_t);
extern "C" cudaError_t __nfcxx_cub_sort_pairs_f32_i32(void *, size_t *, const float *, float *, const int *, int *,
                                                      long long, int, const int *, const int *, int, cudaStream_t);

// CUB's argument order: temporary storage and its size, then the data, then the counts, then the stream.
struct DeviceReduce {
  static cudaError_t Sum(void *tmp, size_t &bytes, const float *in, float *out, long long n, cudaStream_t stream = 0) {
    return __nfcxx_cub_reduce_sum_f32(tmp, &bytes, in, out, n, stream);
  }
};
struct DeviceScan {
  static cudaError_t InclusiveSum(void *tmp, size_t &bytes, const float *in, float *out, long long n,
                                  cudaStream_t stream = 0) {
    return __nfcxx_cub_scan_sum_f32(tmp, &bytes, in, out, n, stream);
  }
  static cudaError_t InclusiveSum(void *tmp, size_t &bytes, const __nv_bfloat16 *in, __nv_bfloat16 *out, long long n,
                                  cudaStream_t stream = 0) {
    return __nfcxx_cub_scan_sum_bf16(tmp, &bytes, (const unsigned short *)in, (unsigned short *)out, n, stream);
  }
};
// The radix sorts take a bit range; ggml-cuda sorts on all 32 bits of a float key, the only range implemented.
struct DeviceRadixSort {
  static cudaError_t SortPairs(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin, int *vout,
                               long long n, int begin_bit = 0, int end_bit = 32, cudaStream_t stream = 0) {
    if (begin_bit != 0 || end_bit != 32) return cudaErrorNotSupported;
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, 0, nullptr, nullptr, 0, stream);
  }
  static cudaError_t SortPairsDescending(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin,
                                         int *vout, long long n, int begin_bit = 0, int end_bit = 32,
                                         cudaStream_t stream = 0) {
    if (begin_bit != 0 || end_bit != 32) return cudaErrorNotSupported;
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, 0, nullptr, nullptr, 1, stream);
  }
};
struct DeviceSegmentedRadixSort {
  static cudaError_t SortPairs(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin, int *vout,
                               long long n, int nseg, const int *begin, const int *end, int begin_bit = 0,
                               int end_bit = 32, cudaStream_t stream = 0) {
    if (begin_bit != 0 || end_bit != 32) return cudaErrorNotSupported;
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, nseg, begin, end, 0, stream);
  }
  static cudaError_t SortPairsDescending(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin,
                                         int *vout, long long n, int nseg, const int *begin, const int *end,
                                         int begin_bit = 0, int end_bit = 32, cudaStream_t stream = 0) {
    if (begin_bit != 0 || end_bit != 32) return cudaErrorNotSupported;
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, nseg, begin, end, 1, stream);
  }
};
struct DeviceSegmentedSort {
  static cudaError_t SortPairs(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin, int *vout,
                               long long n, int nseg, const int *begin, const int *end, cudaStream_t stream = 0) {
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, nseg, begin, end, 0, stream);
  }
  static cudaError_t SortPairsDescending(void *tmp, size_t &bytes, const float *kin, float *kout, const int *vin,
                                         int *vout, long long n, int nseg, const int *begin, const int *end,
                                         cudaStream_t stream = 0) {
    return __nfcxx_cub_sort_pairs_f32_i32(tmp, &bytes, kin, kout, vin, vout, n, nseg, begin, end, 1, stream);
  }
};
// Not implemented: declared only, so a call fails at link time rather than computing nothing.
struct DeviceSegmentedScan {
  template <typename... Args> static cudaError_t InclusiveSegmentedSum(Args &&...);
};
struct DeviceTopK {
  template <typename... Args> static cudaError_t MaxPairs(Args &&...);
};
}  // namespace cub
