// A warp barrier between a shared-memory write and a read of a neighbour's value: each lane of a block writes its
// index to the block's shared array, waits for its warp (__syncwarp(mask) is __nfcxx_syncwarp, which the emitter
// lowers to bar.warp.sync), and reads the next lane's value. The device compile has no CUDA headers, so the mask
// and the thread indices are intrinsic calls, as in vecadd.cpp.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" void __nfcxx_syncwarp(unsigned int mask);

static float buf[32];

void warp_pass(float *out) {
  unsigned t = __nfcxx_tid_x();
  unsigned g = __nfcxx_ctaid_x() * 32 + t;
  buf[t] = (float)t;
  __nfcxx_syncwarp(0xffffffffu);
  out[g] = buf[(t + 1) % 32];
}
