// Host shim for CUB's umbrella header, found before CUDA's own cub/cub.cuh on the host copy's include path (the
// driver adds lib/cuda/host first). CUB 13's headers do not parse in the host front end (CCCL's get_sreg_laneid and
// inline asm constraints), and the host copy never runs device code, so the classes the device unit lowers
// (CUB_DEF in tools/cuda-rewrite/cuda_rewrite.cpp) are declared here with host bodies that return their input.
// DeviceScan is declared only: a host call of it is a launch-and-allocate operation the device unit refuses anyway.
#pragma once
#include <stddef.h>

#include <cuda_runtime.h>

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

struct DeviceScan {
  template <typename... Args> static int InclusiveSum(Args &&...) { return 0; }
};
// Device-wide algorithms are host calls that launch and allocate; the host copy only needs them declared (the device
// unit never contains them), so they fail at link time rather than computing nothing. They return cudaError_t so
// CUDA_CHECK around a call parses (the fix-misc3 shim returned cudaSuccess; origin's DeviceReduce did not).
struct DeviceReduce {
  template <typename... Args> static cudaError_t Sum(Args &&...);
};
struct DeviceRadixSort {
  template <typename... Args> static cudaError_t SortPairs(Args &&...);
  template <typename... Args> static cudaError_t SortPairsDescending(Args &&...);
};
struct DeviceSegmentedRadixSort {
  template <typename... Args> static cudaError_t SortPairs(Args &&...);
  template <typename... Args> static cudaError_t SortPairsDescending(Args &&...);
};
struct DeviceSegmentedSort {
  template <typename... Args> static cudaError_t SortPairs(Args &&...);
  template <typename... Args> static cudaError_t SortPairsDescending(Args &&...);
};
struct DeviceSegmentedScan {
  template <typename... Args> static cudaError_t InclusiveSegmentedSum(Args &&...);
};
struct DeviceTopK {
  template <typename... Args> static cudaError_t MaxPairs(Args &&...);
};
}  // namespace cub
