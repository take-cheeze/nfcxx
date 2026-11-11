// Closure type names across the device pass and the host build (scripts/sycl-build.sh --backend=opencl). The host finds a
// kernel by typeid(F).name(), so the closure's mangled name must match the device IR's. EDG names a closure in a
// translation unit that has no module-id candidate (no external non-inline routine or variable to base it on) with a CRC of
// the source's modification time and the working directory. The device pass ran in build/pathb/edg-base and the host in a
// temporary directory, so the kernel's closure name differed ("no kernel for the closure type"). The ggml-sycl dpct helper
// leaves the translation unit without a candidate, so this program includes it when run.sh passes -DCLOSURE_NAME_DPCT
// with -I of the ggml-sycl source directory (and skips otherwise). Expected output: "closure_name ok".
#ifdef CLOSURE_NAME_DPCT
#include "dpct/helper.hpp"
#endif
#include <sycl/sycl.hpp>
#include <cstdio>

template <typename F>
static void launch(sycl::queue &q, float *pa, float *pr, int n, F f) {
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { pr[i] = f(pa[i]); });
  });
}

inline void run_neg(sycl::queue &q, float *pa, float *pr, int n) {
  launch(q, pa, pr, n, [](float x) { return -x; });
}

int main() {
  const int N = 64;
  float a[N], r[N];
  for (int i = 0; i < N; i++) { a[i] = (float)i - 32.0f; r[i] = -1.0f; }
  {
    sycl::queue q;
    run_neg(q, a, r, N);
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (r[i] != -a[i]) bad++;
  std::printf(bad ? "closure_name FAIL %d\n" : "closure_name ok\n", bad);
  return bad != 0;
}
