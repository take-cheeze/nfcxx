// The oneMKL BLAS names ggml-sycl calls (the dpct helper's gemm wrappers, MUL_MAT's f32 path, out_prod, conv3d,
// fattn-mkl and solve_tri), as plain SYCL kernels of lib/sycl: column-major gemm, gemm_batch (strided, and the group
// form over pointer arrays) and trsm_batch (right side, not transposed). They are reference kernels: one work-item per
// output element (per row for trsm), the products summed in float in index order, so results match a float CPU
// reference to rounding, not oneMKL's blocking. Element types are float, sycl::half and bfloat16, converted to float;
// the result is rounded to the type of C. With beta == 0, C is not read (as in BLAS: a NaN in C does not survive).
// A form not listed, and other element types (double and the complex types, which the dpct helper instantiates for every
// library_data_t but ggml does not call), throw sycl::exception (errc::feature_not_supported) without a kernel.
#pragma once
#include <sycl/sycl.hpp>
#include <sycl/half_type.hpp>
#include <cstdint>
#include <type_traits>
#include <vector>

namespace oneapi {
namespace mkl {
enum class transpose { nontrans, trans, conjtrans };
enum class side { left, right };
enum class uplo { upper, lower };
enum class diag { nonunit, unit };
namespace blas {
namespace column_major {

namespace detail {
template <class T> inline float to_f(T v) { return static_cast<float>(v); }
template <class T> inline T from_f(float v) { return static_cast<T>(v); }
inline bool trans(transpose t) { return t != transpose::nontrans; }   // real types: conjtrans is trans
// the element types the kernels take (float arithmetic on the device)
template <class T> constexpr bool lowp() {
  return std::is_same<T, float>::value || std::is_same<T, sycl::half>::value ||
         std::is_same<T, sycl::ext::oneapi::bfloat16>::value;
}
template <class... T> constexpr bool all_lowp() { return (lowp<T>() && ...); }
[[noreturn]] inline void unsupported() {
  throw sycl::exception(sycl::errc::feature_not_supported, "oneapi::mkl::blas: only float, sycl::half and bfloat16 elements");
}
}  // namespace detail

// C(m x n) = alpha op(A)(m x k) op(B)(k x n) + beta C, for `batch` matrices at the given element strides.
template <class Ts, class Ta, class Tb, class Tc>
sycl::event gemm_batch(sycl::queue &q, transpose ta, transpose tb, std::int64_t m, std::int64_t n, std::int64_t k,
                       Ts alpha, const Ta *a, std::int64_t lda, std::int64_t stride_a, const Tb *b, std::int64_t ldb,
                       std::int64_t stride_b, Ts beta, Tc *c, std::int64_t ldc, std::int64_t stride_c, std::int64_t batch,
                       const std::vector<sycl::event> & = {}) {
  if constexpr (!detail::all_lowp<Ts, Ta, Tb, Tc>()) {
    detail::unsupported();
  } else {
  if (m <= 0 || n <= 0 || batch <= 0) return sycl::event();
  const bool at = detail::trans(ta), bt = detail::trans(tb);
  const float al = detail::to_f(alpha), be = detail::to_f(beta);
  return q.parallel_for(sycl::range<3>((size_t)batch, (size_t)n, (size_t)m), [=](sycl::id<3> id) {
    const std::int64_t p = (std::int64_t)id[0], j = (std::int64_t)id[1], i = (std::int64_t)id[2];
    const Ta *ap = a + p * stride_a;
    const Tb *bp = b + p * stride_b;
    Tc *cp = c + p * stride_c;
    float s = 0.0f;
    for (std::int64_t l = 0; l < k; l++) {
      const float x = detail::to_f(at ? ap[l + i * lda] : ap[i + l * lda]);
      const float y = detail::to_f(bt ? bp[j + l * ldb] : bp[l + j * ldb]);
      s += x * y;
    }
    float r = al * s;
    if (be != 0.0f) r += be * detail::to_f(cp[i + j * ldc]);
    cp[i + j * ldc] = detail::from_f<Tc>(r);
  });
  }
}

template <class Ts, class Ta, class Tb, class Tc>
sycl::event gemm(sycl::queue &q, transpose ta, transpose tb, std::int64_t m, std::int64_t n, std::int64_t k, Ts alpha,
                 const Ta *a, std::int64_t lda, const Tb *b, std::int64_t ldb, Ts beta, Tc *c, std::int64_t ldc,
                 const std::vector<sycl::event> &deps = {}) {
  return gemm_batch(q, ta, tb, m, n, k, alpha, a, lda, 0, b, ldb, 0, beta, c, ldc, 0, 1, deps);
}

// The group form: group g has group_size[g] products sharing its parameters (read on the host); a, b and c are arrays
// (in USM) of one pointer per product, all groups in order.
template <class Ts, class Ta, class Tb, class Tc>
sycl::event gemm_batch(sycl::queue &q, const transpose *ta, const transpose *tb, const std::int64_t *m,
                       const std::int64_t *n, const std::int64_t *k, const Ts *alpha, const Ta **a, const std::int64_t *lda,
                       const Tb **b, const std::int64_t *ldb, const Ts *beta, Tc **c, const std::int64_t *ldc,
                       std::int64_t group_count, const std::int64_t *group_size, const std::vector<sycl::event> & = {}) {
  if constexpr (!detail::all_lowp<Ts, Ta, Tb, Tc>()) {
    detail::unsupported();
  } else {
  std::int64_t first = 0;
  for (std::int64_t g = 0; g < group_count; first += group_size[g], g++) {
    const std::int64_t gm = m[g], gn = n[g], gk = k[g], la = lda[g], lb = ldb[g], lc = ldc[g], cnt = group_size[g];
    if (gm <= 0 || gn <= 0 || cnt <= 0) continue;
    const bool at = detail::trans(ta[g]), bt = detail::trans(tb[g]);
    const float al = detail::to_f(alpha[g]), be = detail::to_f(beta[g]);
    const Ta **ag = a + first;
    const Tb **bg = b + first;
    Tc **cg = c + first;
    q.parallel_for(sycl::range<3>((size_t)cnt, (size_t)gn, (size_t)gm), [=](sycl::id<3> id) {
      const std::int64_t p = (std::int64_t)id[0], j = (std::int64_t)id[1], i = (std::int64_t)id[2];
      const Ta *ap = ag[p];
      const Tb *bp = bg[p];
      Tc *cp = cg[p];
      float s = 0.0f;
      for (std::int64_t l = 0; l < gk; l++) {
        const float x = detail::to_f(at ? ap[l + i * la] : ap[i + l * la]);
        const float y = detail::to_f(bt ? bp[j + l * lb] : bp[l + j * lb]);
        s += x * y;
      }
      float r = al * s;
      if (be != 0.0f) r += be * detail::to_f(cp[i + j * lc]);
      cp[i + j * lc] = detail::from_f<Tc>(r);
    });
  }
  return sycl::event();
  }
}

// B(m x n) := alpha B op(A)^-1 for side right with op(A) = A: X A = alpha B is solved in place, column by column, one
// work-item per row of one matrix. A is n x n, upper or lower triangular.
template <class T>
sycl::event trsm_batch(sycl::queue &q, side sd, uplo ul, transpose ta, diag dg, std::int64_t m, std::int64_t n, T alpha,
                       const T *a, std::int64_t lda, std::int64_t stride_a, T *b, std::int64_t ldb, std::int64_t stride_b,
                       std::int64_t batch, const std::vector<sycl::event> & = {}) {
  if constexpr (!detail::all_lowp<T>()) {
    detail::unsupported();
  } else {
  if (sd != side::right || ta != transpose::nontrans)
    throw sycl::exception(sycl::errc::feature_not_supported, "oneapi::mkl::blas::trsm_batch: only side::right with transpose::nontrans");
  if (m <= 0 || n <= 0 || batch <= 0) return sycl::event();
  const bool upper = ul == uplo::upper, unit = dg == diag::unit;
  const float al = (float)alpha;
  return q.parallel_for(sycl::range<2>((size_t)batch, (size_t)m), [=](sycl::id<2> id) {
    const std::int64_t p = (std::int64_t)id[0], i = (std::int64_t)id[1];
    const T *ap = a + p * stride_a;
    T *bp = b + p * stride_b;
    // upper: X(i, j) needs X(i, l) for l < j, so j runs up; lower: for l > j, so j runs down
    for (std::int64_t t = 0; t < n; t++) {
      const std::int64_t j = upper ? t : n - 1 - t;
      float s = al * (float)bp[i + j * ldb];
      const std::int64_t lo = upper ? 0 : j + 1, hi = upper ? j : n;
      for (std::int64_t l = lo; l < hi; l++) s -= (float)bp[i + l * ldb] * (float)ap[l + j * lda];
      if (!unit) s /= (float)ap[j + j * lda];
      bp[i + j * ldb] = (T)s;
    }
  });
  }
}

}  // namespace column_major
// oneMKL's blas namespace has the column-major forms directly
using column_major::gemm;
using column_major::gemm_batch;
using column_major::trsm_batch;
}  // namespace blas
}  // namespace mkl
}  // namespace oneapi
