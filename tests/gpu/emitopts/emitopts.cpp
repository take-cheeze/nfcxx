// The SPIR-V emitter's release-build lowerings (scripts/pathb-spirv-emit.rb, tools/pathb-spirv-emit), each checked for its
// results here and for its module shape by run.sh:
//   - divisions and remainders by constants (no zero or overflow guard), shifts by constants (no count check);
//   - a bounds-checked local array and pointer dereferences (the checks that --no-checks, sycl-build.rb --ndebug, drops);
//   - a call that survives inlining (a struct parameter) of a function that cannot trap: no dead-flag test after it;
//   - dpct::dp4a(int, int, int) as ggml-sycl's dpct/helper.hpp spells it (a template over sycl::vec), which the
//     lib/sycl-ggml overload turns into the intrinsic __nfcxx_sycl_dp4a (OpSDot in the OpenCL module).
// Expected output: "emitopts ok".
#include <sycl/sycl.hpp>
#include <sycl/half_type.hpp>   // lib/sycl-ggml: declares the dpct::dp4a(int, int, int) overload, as the dpct helper sees it
#include <cstdint>
#include <cstdio>
#include <vector>

namespace dpct {
// the helper's generic template (dpct/helper.hpp): the device pass must not choose it for int operands
template <class T1, class T2, class T3> inline auto dp4a(T1 a, T2 b, T3 c) {
  int res = c;
  for (int k = 0; k < 4; k++) res += (int)(int8_t)((unsigned)a >> (8 * k)) * (int)(int8_t)((unsigned)b >> (8 * k));
  return res;
}
}  // namespace dpct

struct pair2 {
  int a, b;
};
// a struct parameter: the inliner keeps the call, and the callee cannot trap
static int helper(pair2 p, int k) { return p.a * k + p.b; }

static void compute(int x, int a, int b, int c, unsigned i, int *o) {
  unsigned u = (unsigned)x;
  o[0] = (int)(u / 7u + u % 16u + (u >> 3) + (u << 2));
  o[1] = x / -3 + x % 5 + (x >> 1);
  int t[4] = {x, x + 1, x + 2, x + 3};
  o[2] = t[i & 3];
  o[3] = helper(pair2{x, 1}, 3);
  o[4] = dpct::dp4a(a, b, c);
}

int main() {
  const int N = 4096, K = 5;
  std::vector<int> x(N), a(N), b(N), c(N), out(N * K, 0), ref(N * K);
  uint32_t s = 12345;
  auto next = [&s]() { s = s * 1664525u + 1013904223u; return (int)s; };
  for (int i = 0; i < N; i++) {
    x[i] = next();
    a[i] = next();
    b[i] = next();
    c[i] = i % 7 == 0 ? 0x7fffffff : next();   // the dot product's sum wraps: both sides wrap the same way
    if (i % 11 == 0) x[i] = INT32_MIN + i;      // x / -3 of these is defined; INT_MIN itself is not used
    compute(x[i], a[i], b[i], c[i], (unsigned)i, &ref[i * K]);
  }
  {
    sycl::queue q;
    sycl::buffer<int, 1> X(x.data(), sycl::range<1>(N)), A(a.data(), sycl::range<1>(N)), B(b.data(), sycl::range<1>(N)),
        C(c.data(), sycl::range<1>(N)), O(out.data(), sycl::range<1>(N * K));
    q.submit([&](sycl::handler &h) {
      sycl::accessor rx(X, h, sycl::read_only), ra(A, h, sycl::read_only), rb(B, h, sycl::read_only),
          rc(C, h, sycl::read_only);
      sycl::accessor wo(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        int r[5];
        compute(rx[i], ra[i], rb[i], rc[i], (unsigned)i[0], r);
        for (int k = 0; k < K; k++) wo[i[0] * K + k] = r[k];
      });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N * K; i++)
    if (out[i] != ref[i]) {
      if (bad < 5) std::printf("mismatch at %d (item %d, value %d): %d, want %d\n", i, i / K, i % K, out[i], ref[i]);
      bad++;
    }
  std::printf(bad ? "emitopts FAIL %d\n" : "emitopts ok\n", bad);
  return bad != 0;
}
