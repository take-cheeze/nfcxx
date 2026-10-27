// In place of ggml-sycl's fused-gemm.cpp for a libggml-sycl built by nfcxx (scripts/ggml-sycl-lib.sh): the fused and
// grouped dequantizing GEMMs are joint_matrix kernels, which lib/sycl does not have. Both entry points decline (false),
// and the caller takes its unfused path, as it does for a shape the fused kernels do not take.
#include "fused-gemm.hpp"

bool ggml_sycl_fused_dequant_gemm(ggml_type, const void *, const void *, ggml_type, int32_t, float *, int64_t, int64_t,
                                  int64_t, int64_t, ggml_sycl_pool &, dpct::queue_ptr) {
    return false;
}

bool ggml_sycl_grouped_dequant_gemm(ggml_type, bool, const void *, size_t, const float *, int32_t, float *,
                                    const int64_t *, int64_t, int64_t, int64_t, int64_t, std::vector<ggml_sycl_gg_tile> &,
                                    ggml_sycl_pool &, dpct::queue_ptr) {
    return false;
}
