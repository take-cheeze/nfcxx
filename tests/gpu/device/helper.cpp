// Device helper functions called from kernels (the device side of tests/gpu/device/vecadd.cpp: the thread indices
// are extern "C" intrinsics, and the device compile has no CUDA headers). helper_kernel calls square_plus_one, which
// calls square (a helper calling a helper); helper_scale calls scale, which returns a float.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

extern "C" int square(int x) { return x * x; }
extern "C" int square_plus_one(int x) { return square(x) + 1; }
extern "C" float scale(float v) { return v * 0.5f + 1.0f; }

extern "C" void helper_kernel(const int *in, int *out, int n) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) {
    out[i] = square_plus_one(in[i]);
  }
}

extern "C" void helper_scale(const float *in, float *out, int n) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) {
    out[i] = scale(in[i]);
  }
}
