// Atomics in a device kernel: integer and float add, integer max, an add through a computed address (a histogram),
// and compare-and-swap (the first thread to see the sentinel wins). The intrinsics take the pointer (ATOMICS in the emitter).
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);
extern "C" int __nfcxx_atomic_add_i(int *p, int v);
extern "C" float __nfcxx_atomic_add_f(float *p, float v);
extern "C" int __nfcxx_atomic_max_i(int *p, int v);
extern "C" int __nfcxx_atomic_cas_i(int *p, int cmp, int v);

void atomics(const int *in, int *total, float *ftotal, int *maxv, int *bins, int *cas, int *wins, int n) {
  int i = (int)(__nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x());
  if (i < n) {
    int x = in[i];
    __nfcxx_atomic_add_i(total, x);
    __nfcxx_atomic_add_f(ftotal, (float)x);
    __nfcxx_atomic_max_i(maxv, x);
    __nfcxx_atomic_add_i(&bins[x & 7], 1);
    if (__nfcxx_atomic_cas_i(cas, -1000, x) == -1000) __nfcxx_atomic_add_i(wins, 1);
  }
}
