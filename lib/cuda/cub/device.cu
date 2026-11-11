// The device-wide CUB algorithms that ggml-cuda calls (sum.cu and mean.cu: DeviceReduce::Sum; cumsum.cu:
// DeviceScan::InclusiveSum; argsort.cu: DeviceRadixSort, DeviceSegmentedRadixSort and DeviceSegmentedSort SortPairs),
// built by the nfcxx driver itself (scripts/cuda-cub) and linked into hosted links that name -lcudart. The host shim
// (lib/cuda/host/cub/cub.cuh) forwards its overloads to the C functions here. CUB's protocol is kept: a call with a
// null temporary storage only sets the size it needs; the second call does the work, on the given stream.
//
// The results are CUB's: the sum and the scan accumulate in float (the scan of bf16 rounds each output once), and the
// sorts are stable and order the keys as CUB's radix sort does (each float's bits mapped to an unsigned key, so
// -0 < +0 and NaNs sort past the infinities). Descending sorts invert the mapped key, so equal keys keep their order.
// Speed is not the aim: the sum and the scan are one block, the sort is a bottom-up merge sort (log2(n) passes).
#include <cuda_runtime.h>
#include <stddef.h>

static const int kThreads = 1024;

static __global__ void cub_sum_f32(const float *in, float *out, long long n) {
  __shared__ float part[kThreads];
  float acc = 0.0f;
  for (long long i = threadIdx.x; i < n; i += kThreads) acc += in[i];
  part[threadIdx.x] = acc;
  __syncthreads();
  for (int w = kThreads / 2; w > 0; w >>= 1) {
    if ((int)threadIdx.x < w) part[threadIdx.x] += part[threadIdx.x + w];
    __syncthreads();
  }
  if (threadIdx.x == 0) out[0] = part[0];
}

// The bits of a float as a float (the device prelude has __float_as_uint but not this direction).
static __device__ float as_float(unsigned u) { return *(const float *)&u; }

static __device__ float bf16_to_float(unsigned short b) {
  return as_float((unsigned)b << 16);
}

static __device__ unsigned short float_to_bf16(float f) {
  unsigned x = __float_as_uint(f);
  if ((x & 0x7fffffffu) > 0x7f800000u) return 0x7fffu;
  x += 0x7fffu + ((x >> 16) & 1u);
  return (unsigned short)(x >> 16);
}

// One block walks the input in chunks of kThreads, with the running total of the chunks before (carry).
static __device__ float block_inclusive_scan(float v, float *buf) {
  buf[threadIdx.x] = v;
  __syncthreads();
  for (int off = 1; off < kThreads; off <<= 1) {
    float u = (int)threadIdx.x >= off ? buf[threadIdx.x - off] : 0.0f;
    __syncthreads();
    buf[threadIdx.x] += u;
    __syncthreads();
  }
  return buf[threadIdx.x];
}

static __global__ void cub_scan_f32(const float *in, float *out, long long n) {
  __shared__ float buf[kThreads];
  __shared__ float carry;
  if (threadIdx.x == 0) carry = 0.0f;
  __syncthreads();
  for (long long base = 0; base < n; base += kThreads) {
    const long long i = base + threadIdx.x;
    float s = block_inclusive_scan(i < n ? in[i] : 0.0f, buf);
    if (i < n) out[i] = s + carry;
    __syncthreads();
    if (threadIdx.x == kThreads - 1) carry += s;
    __syncthreads();
  }
}

static __global__ void cub_scan_bf16(const unsigned short *in, unsigned short *out, long long n) {
  __shared__ float buf[kThreads];
  __shared__ float carry;
  if (threadIdx.x == 0) carry = 0.0f;
  __syncthreads();
  for (long long base = 0; base < n; base += kThreads) {
    const long long i = base + threadIdx.x;
    float s = block_inclusive_scan(i < n ? bf16_to_float(in[i]) : 0.0f, buf);
    if (i < n) out[i] = float_to_bf16(s + carry);
    __syncthreads();
    if (threadIdx.x == kThreads - 1) carry += s;
    __syncthreads();
  }
}

// The radix order of a float: negative values have all their bits inverted, the others only the sign bit.
static __device__ unsigned key_of(float f, unsigned flip) {
  unsigned u = __float_as_uint(f);
  return (u ^ ((u & 0x80000000u) ? 0xffffffffu : 0x80000000u)) ^ flip;
}

static __device__ float float_of(unsigned k, unsigned flip) {
  k ^= flip;
  return as_float(k ^ ((k & 0x80000000u) ? 0x80000000u : 0xffffffffu));
}

static __global__ void cub_sort_init(const float *kin, const int *vin, unsigned *keys, int *vals, long long n, unsigned flip) {
  const long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  keys[i] = key_of(kin[i], flip);
  vals[i] = vin[i];
}

static __global__ void cub_sort_final(const unsigned *keys, const int *vals, float *kout, int *vout, long long n, unsigned flip) {
  const long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  kout[i] = float_of(keys[i], flip);
  vout[i] = vals[i];
}

// The segment of item i: [begin, end) of the last segment that begins at or before i, or i alone when no segment
// holds it (CUB leaves such items out; here they stay where they are).
static __device__ void segment_of(long long i, long long n, int nseg, const int *begin, const int *end, long long &b,
                           long long &e) {
  if (nseg == 0) {
    b = 0;
    e = n;
    return;
  }
  int lo = 0, hi = nseg;  // the first segment whose begin is past i
  while (lo < hi) {
    const int mid = (lo + hi) / 2;
    if (begin[mid] <= i) lo = mid + 1;
    else hi = mid;
  }
  if (lo == 0 || i >= end[lo - 1]) {
    b = i;
    e = i + 1;
    return;
  }
  b = begin[lo - 1];
  e = end[lo - 1];
}

// One merge pass of width w: runs of w items, pairwise merged. An item of the left run goes before the equal items of
// the right one (lower bound there), an item of the right run after the equal ones of the left (upper bound), so the
// merge is stable.
static __global__ void cub_sort_merge(const unsigned *keys, const int *vals, unsigned *okeys, int *ovals, long long n, int nseg,
                           const int *begin, const int *end, long long w) {
  const long long i = (long long)blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  long long sb, se;
  segment_of(i, n, nseg, begin, end, sb, se);
  const long long run = (i - sb) / w;
  const long long start = sb + run * w;
  const unsigned k = keys[i];
  long long pos;
  if (run % 2 == 0) {
    const long long ob = start + w < se ? start + w : se, oe = start + 2 * w < se ? start + 2 * w : se;
    long long lo = ob, hi = oe;
    while (lo < hi) {
      const long long mid = (lo + hi) / 2;
      if (keys[mid] < k) lo = mid + 1;
      else hi = mid;
    }
    pos = start + (i - start) + (lo - ob);
  } else {
    const long long ob = start - w, oe = start;
    long long lo = ob, hi = oe;
    while (lo < hi) {
      const long long mid = (lo + hi) / 2;
      if (keys[mid] <= k) lo = mid + 1;
      else hi = mid;
    }
    pos = ob + (i - start) + (lo - ob);
  }
  okeys[pos] = k;
  ovals[pos] = vals[i];
}

static long long blocks_for(long long n) { return (n + 255) / 256; }

extern "C" cudaError_t __nfcxx_cub_reduce_sum_f32(void *tmp, size_t *bytes, const float *in, float *out, long long n,
                                                  cudaStream_t stream) {
  if (tmp == nullptr) {
    *bytes = 16;
    return cudaSuccess;
  }
  cub_sum_f32<<<1, kThreads, 0, stream>>>(in, out, n);
  return cudaGetLastError();
}

extern "C" cudaError_t __nfcxx_cub_scan_sum_f32(void *tmp, size_t *bytes, const float *in, float *out, long long n,
                                                cudaStream_t stream) {
  if (tmp == nullptr) {
    *bytes = 16;
    return cudaSuccess;
  }
  if (n > 0) cub_scan_f32<<<1, kThreads, 0, stream>>>(in, out, n);
  return cudaGetLastError();
}

extern "C" cudaError_t __nfcxx_cub_scan_sum_bf16(void *tmp, size_t *bytes, const unsigned short *in,
                                                 unsigned short *out, long long n, cudaStream_t stream) {
  if (tmp == nullptr) {
    *bytes = 16;
    return cudaSuccess;
  }
  if (n > 0) cub_scan_bf16<<<1, kThreads, 0, stream>>>(in, out, n);
  return cudaGetLastError();
}

// nseg = 0: one segment of n items. Otherwise segment s is [begin[s], end[s]) (device arrays, ascending).
extern "C" cudaError_t __nfcxx_cub_sort_pairs_f32_i32(void *tmp, size_t *bytes, const float *kin, float *kout,
                                                      const int *vin, int *vout, long long n, int nseg,
                                                      const int *begin, const int *end, int descending,
                                                      cudaStream_t stream) {
  const size_t need = (size_t)(n > 0 ? n : 1) * 16 + 256;
  if (tmp == nullptr) {
    *bytes = need;
    return cudaSuccess;
  }
  if (*bytes < need) return cudaErrorInvalidValue;
  if (n <= 0) return cudaSuccess;
  unsigned *ka = (unsigned *)tmp, *kb = ka + n;
  int *va = (int *)(kb + n), *vb = va + n;
  const unsigned flip = descending ? 0xffffffffu : 0u;
  const long long g = blocks_for(n);
  cub_sort_init<<<(unsigned)g, 256, 0, stream>>>(kin, vin, ka, va, n, flip);
  for (long long w = 1; w < n; w *= 2) {
    cub_sort_merge<<<(unsigned)g, 256, 0, stream>>>(ka, va, kb, vb, n, nseg, begin, end, w);
    unsigned *tk = ka; ka = kb; kb = tk;
    int *tv = va; va = vb; vb = tv;
  }
  cub_sort_final<<<(unsigned)g, 256, 0, stream>>>(ka, va, kout, vout, n, flip);
  return cudaGetLastError();
}
