// The oneMKL subset of lib/sycl-ggml/oneapi/mkl.hpp on the device, against a double-precision host reference:
// column-major gemm for the four transpose pairs (f32, and f16 inputs with an f32 result), strided gemm_batch, the group
// form of gemm_batch over pointer arrays, and trsm_batch (side right, upper and lower). Prints one line per check and
// "checks: N, failed: K".
#include <sycl/sycl.hpp>
#include <sycl/half_type.hpp>
#include <oneapi/mkl.hpp>
#include <cmath>
#include <cstdio>
#include <vector>

using oneapi::mkl::transpose;
namespace blas = oneapi::mkl::blas::column_major;

static int nchecks = 0, nfailed = 0;
static void report(const char *what, double err, double tol) {
  nchecks++;
  bool ok = err <= tol;
  if (!ok) nfailed++;
  printf("%s: max rel err %.3g: %s\n", what, err, ok ? "ok" : "FAIL");
}
static float val(int i) { return (float)((i * 37 % 23) - 11) / 8.0f; }

// reference C = alpha op(A) op(B) + beta C (column major)
static void ref_gemm(bool at, bool bt, int m, int n, int k, double al, const float *a, int lda, const float *b, int ldb,
                     double be, double *c, int ldc) {
  for (int j = 0; j < n; j++)
    for (int i = 0; i < m; i++) {
      double s = 0;
      for (int l = 0; l < k; l++) s += (double)(at ? a[l + i * lda] : a[i + l * lda]) * (bt ? b[j + l * ldb] : b[l + j * ldb]);
      c[i + j * ldc] = al * s + be * c[i + j * ldc];
    }
}
static double rel_err(const float *got, const double *want, int count) {
  double e = 0, scale = 1e-6;
  for (int i = 0; i < count; i++) scale = std::fmax(scale, std::fabs(want[i]));
  for (int i = 0; i < count; i++) e = std::fmax(e, std::fabs((double)got[i] - want[i]) / scale);
  return e;
}

int main() {
  sycl::queue q{sycl::gpu_selector_v};
  printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());
  const int m = 37, n = 29, k = 53, ld = 64, batch = 3;
  float *a = sycl::malloc_shared<float>(ld * ld * batch, q), *b = sycl::malloc_shared<float>(ld * ld * batch, q);
  float *c = sycl::malloc_shared<float>(ld * ld * batch, q);
  sycl::half *ah = sycl::malloc_shared<sycl::half>(ld * ld, q), *bh = sycl::malloc_shared<sycl::half>(ld * ld, q);
  std::vector<float> ar(ld * ld * batch), br(ld * ld * batch);
  for (int i = 0; i < ld * ld * batch; i++) { a[i] = ar[i] = val(i); b[i] = br[i] = val(i + 5); }
  for (int i = 0; i < ld * ld; i++) { ah[i] = sycl::half(a[i]); bh[i] = sycl::half(b[i]); }   // the values are exact in f16
  std::vector<double> want(ld * ld * batch);
  char name[96];

  for (int t = 0; t < 4; t++) {
    bool at = t & 1, bt = t & 2;
    transpose ta = at ? transpose::trans : transpose::nontrans, tb = bt ? transpose::trans : transpose::nontrans;
    for (int i = 0; i < ld * ld; i++) { c[i] = val(i + 9); want[i] = c[i]; }
    blas::gemm(q, ta, tb, m, n, k, 0.5f, a, ld, b, ld, 2.0f, c, ld).wait();
    ref_gemm(at, bt, m, n, k, 0.5, ar.data(), ld, br.data(), ld, 2.0, want.data(), ld);
    snprintf(name, sizeof name, "gemm f32 %c%c", at ? 't' : 'n', bt ? 't' : 'n');
    report(name, rel_err(c, want.data(), ld * ld), 1e-5);
    for (int i = 0; i < ld * ld; i++) { c[i] = std::nanf(""); want[i] = 0; }   // beta 0: C is not read
    blas::gemm(q, ta, tb, m, n, k, 1.0f, ah, ld, bh, ld, 0.0f, c, ld).wait();
    ref_gemm(at, bt, m, n, k, 1.0, ar.data(), ld, br.data(), ld, 0.0, want.data(), ld);
    for (int j = 0; j < ld; j++) for (int i = 0; i < ld; i++) if (i >= m || j >= n) { c[i + j * ld] = 0; }
    snprintf(name, sizeof name, "gemm f16->f32 %c%c beta 0", at ? 't' : 'n', bt ? 't' : 'n');
    report(name, rel_err(c, want.data(), ld * ld), 1e-5);
  }

  // strided batch
  const long long st = ld * ld;
  for (int i = 0; i < ld * ld * batch; i++) { c[i] = val(i + 3); want[i] = c[i]; }
  blas::gemm_batch(q, transpose::trans, transpose::nontrans, m, n, k, 1.5f, a, ld, st, b, ld, st, -1.0f, c, ld, st, batch).wait();
  for (int p = 0; p < batch; p++)
    ref_gemm(true, false, m, n, k, 1.5, ar.data() + p * st, ld, br.data() + p * st, ld, -1.0, want.data() + p * st, ld);
  report("gemm_batch strided tn", rel_err(c, want.data(), ld * ld * batch), 1e-5);

  // the group form, one group of `batch` products, pointers in USM
  const float **ap = sycl::malloc_shared<const float *>(batch, q), **bp = sycl::malloc_shared<const float *>(batch, q);
  float **cp = sycl::malloc_shared<float *>(batch, q);
  for (int p = 0; p < batch; p++) { ap[p] = a + p * st; bp[p] = b + p * st; cp[p] = c + p * st; }
  for (int i = 0; i < ld * ld * batch; i++) { c[i] = val(i + 1); want[i] = c[i]; }
  transpose tas[1] = {transpose::nontrans}, tbs[1] = {transpose::trans};
  std::int64_t ms[1] = {m}, ns[1] = {n}, ks[1] = {k}, lds[1] = {ld}, gs[1] = {batch};
  float als[1] = {1.0f}, bes[1] = {0.25f};
  blas::gemm_batch(q, tas, tbs, ms, ns, ks, als, ap, lds, bp, lds, bes, cp, lds, 1, gs).wait();
  q.wait();
  for (int p = 0; p < batch; p++)
    ref_gemm(false, true, m, n, k, 1.0, ar.data() + p * st, ld, br.data() + p * st, ld, 0.25, want.data() + p * st, ld);
  report("gemm_batch group nt", rel_err(c, want.data(), ld * ld * batch), 1e-5);

  // trsm_batch, side right: X A = alpha B, A n x n triangular with a heavy diagonal
  const int tm = 21, tn = 17;
  for (int up = 0; up < 2; up++) {
    float *ta_ = sycl::malloc_shared<float>(tn * tn * batch, q), *tb_ = sycl::malloc_shared<float>(tm * tn * batch, q);
    std::vector<float> x0(tm * tn * batch);
    for (int p = 0; p < batch; p++)
      for (int j = 0; j < tn; j++)
        for (int l = 0; l < tn; l++) {
          bool in = up ? l <= j : l >= j;
          ta_[p * tn * tn + l + j * tn] = l == j ? 4.0f + val(p + j) : (in ? val(l * 3 + j + p) : 999.0f);   // 999: never read
        }
    for (int i = 0; i < tm * tn * batch; i++) tb_[i] = x0[i] = val(i + 7);
    oneapi::mkl::blas::trsm_batch(q, oneapi::mkl::side::right, up ? oneapi::mkl::uplo::upper : oneapi::mkl::uplo::lower,
                                  transpose::nontrans, oneapi::mkl::diag::nonunit, tm, tn, 2.0f, ta_, tn, tn * tn, tb_, tm,
                                  tm * tn, batch).wait();
    // check X A == 2 B0
    std::vector<double> lhs(tm * tn * batch), rhs(tm * tn * batch);
    std::vector<float> got(tm * tn * batch);
    for (int p = 0; p < batch; p++)
      for (int j = 0; j < tn; j++)
        for (int i = 0; i < tm; i++) {
          double s = 0;
          for (int l = 0; l < tn; l++) {
            bool in = up ? l <= j : l >= j;
            if (in) s += (double)tb_[p * tm * tn + i + l * tm] * ta_[p * tn * tn + l + j * tn];
          }
          got[p * tm * tn + i + j * tm] = (float)s;
          rhs[p * tm * tn + i + j * tm] = 2.0 * x0[p * tm * tn + i + j * tm];
        }
    report(up ? "trsm_batch right upper" : "trsm_batch right lower", rel_err(got.data(), rhs.data(), tm * tn * batch), 1e-5);
    sycl::free(ta_, q);
    sycl::free(tb_, q);
  }
  printf("checks: %d, failed: %d\n", nchecks, nfailed);
  return nfailed != 0;
}
