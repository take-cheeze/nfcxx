// A switch in a device kernel: case 1 falls through to case 2, case 2 breaks, case 3 and 4 break, default is the
// rest (pathb-stage2 section 2). Device-side convention of vecadd.cpp: the thread index is an intrinsic call.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

void classify(const int *in, int *out, int n) {
  int i = (int)(__nfcxx_tid_x() + __nfcxx_ctaid_x() * __nfcxx_ntid_x());
  if (i < n) {
    int x = in[i];
    int r = 0;
    switch (x) {
      case 1: r = 10;
      case 2: r += 5; break;
      case 3: r = 7; break;
      case 4: r = 100; break;
      default: r = -1;
    }
    out[i] = r;
  }
}
