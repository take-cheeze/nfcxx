// Block-level reversal through block-shared memory: each block of 128 threads loads its slice into the tile, waits at
// the barrier, and writes the slice back reversed. The device compile has no CUDA headers, so the shared array is a
// file-scope static (the emitter lowers a zero-initialized static array of the device unit as __shared__), and the
// barrier is an intrinsic call (tools/pathb-ptx-emit: __nfcxx_syncthreads -> bar.sync 0).
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" void __nfcxx_syncthreads(void);

static float tile[128];

void reverse_block(const float *in, float *out) {
  unsigned t = __nfcxx_tid_x();
  unsigned g = __nfcxx_ctaid_x() * 128 + t;
  tile[t] = in[g];
  __nfcxx_syncthreads();
  out[g] = tile[127 - t];
}
