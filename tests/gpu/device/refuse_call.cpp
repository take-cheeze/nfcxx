extern "C" unsigned __nfcxx_tid_x(void);
unsigned helper(unsigned x);

void k(float *A) {
  A[0] = (float)helper(__nfcxx_tid_x());
}
