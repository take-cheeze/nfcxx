// Device memory and bool constructs, device side (the intrinsic convention of vecadd.cpp; no CUDA headers).
// k_bool: bool in memory (one byte) and in registers, and the conversion of a bool to int.
// k_local_shared: a function-local __shared__ array (a static in the kernel), with a barrier.
// k_global: a zero-initialized __device__ global array, written and read back by the same thread.
// k_offset: a field of a struct behind a pointer (the address of the field, offset).
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);
extern "C" void __nfcxx_syncthreads(void);

int g_table[256];

struct Pair {
  int a;
  int b;
};

extern "C" void k_bool(bool *flag, int *out, int n) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) {
    bool f = (i % 3) == 0;
    flag[i] = f;
    bool g = flag[i];
    out[i] = (g ? 7 : 3) + (int)f;
  }
}

extern "C" void k_local_shared(int *out, const int *in) {
  static int tile[64];
  unsigned t = __nfcxx_tid_x();
  unsigned g = __nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x();
  tile[t] = in[g];
  __nfcxx_syncthreads();
  out[g] = tile[63 - t];
}

extern "C" void k_global(int *out) {
  unsigned i = __nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x();
  g_table[i] = (int)i * 2;
  out[i] = g_table[i] + 1;
}

extern "C" void k_offset(int *out, const Pair *p, int n) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) out[i] = p[i].b - p[i].a;
}
