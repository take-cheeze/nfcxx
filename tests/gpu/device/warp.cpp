// Warp intrinsics in a device kernel: a shuffle-xor sum over the warp, a float shuffle, ballot, any and all. The
// intrinsics are extern "C" calls that the emitter lowers (WARP_SHUFFLES, WARP_VOTES); the mask is the full warp.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);
extern "C" int __nfcxx_shfl_xor_sync_i(unsigned mask, int v, int lane);
extern "C" float __nfcxx_shfl_xor_sync_f(unsigned mask, float v, int lane);
extern "C" unsigned __nfcxx_ballot_sync(unsigned mask, int pred);
extern "C" int __nfcxx_any_sync(unsigned mask, int pred);
extern "C" int __nfcxx_all_sync(unsigned mask, int pred);

void warp_ops(const int *in, int *sum, float *fswap, unsigned *ballot, int *flags, int n) {
  int i = (int)(__nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x());
  int v = i < n ? in[i] : 0;
  float fv = (float)v;
  int s = v;
  for (int off = 16; off > 0; off >>= 1) s += __nfcxx_shfl_xor_sync_i(0xffffffffu, s, off);
  sum[i] = s;
  fswap[i] = __nfcxx_shfl_xor_sync_f(0xffffffffu, fv, 1);
  int big = v > 3;
  unsigned b = __nfcxx_ballot_sync(0xffffffffu, big);
  int any = __nfcxx_any_sync(0xffffffffu, big);
  int all = __nfcxx_all_sync(0xffffffffu, big);
  ballot[i] = b;
  flags[i] = any | (all << 1);
}
