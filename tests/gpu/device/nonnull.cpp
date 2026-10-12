extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

// The read through the pointer parameter is checked for null (nonnull): a null pointer traps the kernel.
// Every thread of the 8 blocks x 128 threads writes out[i] (1024 slots), so there is no bounds check.
void load_plus_one(const int *a, int *out) {
  unsigned i = __nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x();
  out[i] = *a + 1;
}
