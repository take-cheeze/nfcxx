// Declarations of the oneMKL names the dpct helper calls (its BLAS wrappers). They are declared, not implemented: the
// ops under test do not reach them yet, and a call that is reached fails at link time, not here.
#pragma once
#include <sycl/sycl.hpp>
namespace oneapi {
namespace mkl {
enum class transpose { nontrans, trans, conjtrans };
namespace blas {
namespace column_major {
template <class... A> sycl::event gemm(A...);
template <class... A> sycl::event gemm_batch(A...);
}  // namespace column_major
}  // namespace blas
}  // namespace mkl
}  // namespace oneapi
